# frozen_string_literal: true

module PSX
  # DMA Controller
  # Handles bulk memory transfers between RAM and devices
  class DMA
    # DMA Channels
    MDEC_IN  = 0  # MDEC decoder input
    MDEC_OUT = 1  # MDEC decoder output
    GPU      = 2  # Graphics Processing Unit
    CDROM    = 3  # CD-ROM drive
    SPU      = 4  # Sound Processing Unit
    PIO      = 5  # Expansion port
    OTC      = 6  # Ordering Table Clear

    NUM_CHANNELS = 7

    # Channel control register bits
    CTRL_DIRECTION    = 0x0000_0001  # 0=To RAM, 1=From RAM
    CTRL_STEP         = 0x0000_0002  # 0=Forward (+4), 1=Backward (-4)
    CTRL_CHOPPING     = 0x0000_0100  # Enable chopping
    CTRL_SYNC_MODE    = 0x0000_0600  # Sync mode (bits 9-10)
    CTRL_CHOP_DMA     = 0x0007_0000  # Chopping DMA window (bits 16-18)
    CTRL_CHOP_CPU     = 0x0700_0000  # Chopping CPU window (bits 20-22)
    CTRL_START_BUSY   = 0x0100_0000  # Start/Busy (bit 24)
    CTRL_START_TRIGGER = 0x1000_0000 # Start trigger (bit 28)

    # Sync modes
    SYNC_MANUAL  = 0  # Transfer all at once (burst)
    SYNC_REQUEST = 1  # Sync blocks to DRQ
    SYNC_LINKED  = 2  # Linked list mode (GPU only)

    # DICR bits
    DICR_FORCE_IRQ    = 0x0000_8000  # Force IRQ (bit 15)
    DICR_IRQ_ENABLE   = 0x007F_0000  # Per-channel IRQ enable (bits 16-22)
    DICR_IRQ_MASTER   = 0x0080_0000  # Master IRQ enable (bit 23)
    DICR_IRQ_FLAGS    = 0x7F00_0000  # Per-channel IRQ flags (bits 24-30)
    DICR_IRQ_MASTER_FLAG = 0x8000_0000  # Master IRQ flag (bit 31)

    class Channel
      attr_accessor :base_addr, :block_ctrl, :channel_ctrl

      def initialize
        @base_addr = 0
        @block_ctrl = 0
        @channel_ctrl = 0
      end

      def active?(needs_trigger: false)
        # Channel is active when Start/Busy bit is set.
        # SyncMode 0 (Manual) without a DRQ-driving device (e.g. OTC) also
        # needs the start-trigger bit. Channels with DRQ (GPU, SPU, CDROM,
        # ...) auto-start when BUSY is set.
        enabled = (@channel_ctrl & CTRL_START_BUSY) != 0
        return false unless enabled

        if needs_trigger
          (@channel_ctrl & CTRL_START_TRIGGER) != 0
        else
          true
        end
      end

      def direction
        (@channel_ctrl & CTRL_DIRECTION) != 0 ? :from_ram : :to_ram
      end

      def step
        (@channel_ctrl & CTRL_STEP) != 0 ? -4 : 4
      end

      def sync_mode
        (@channel_ctrl >> 9) & 0x3
      end

      def block_size
        @block_ctrl & 0xFFFF
      end

      def block_count
        (@block_ctrl >> 16) & 0xFFFF
      end

      def finish!
        # On transfer completion: bit 24 (Start/Busy) and bit 28 (Start/
        # Trigger) both clear. Bit 28 is "consumed" by the transfer it
        # triggered. Unused R/W bits (29/30) keep their values.
        # Verified against ps1-tests/dma/otc-test:
        #   testOtcWhichBitsAreHardwiredToZero -- bit 28 stays when no
        #     transfer happens (busy bit wasn't set, finish! isn't called).
        #   testOtcControlBitsAfterTransfer   -- bit 28 cleared after
        #     transfer actually ran.
        @channel_ctrl &= ~(CTRL_START_BUSY | CTRL_START_TRIGGER)
      end
    end

    attr_reader :channels, :dpcr, :dicr
    attr_accessor :spu

    def initialize(interrupts: nil, spu: nil)
      @interrupts = interrupts
      @spu = spu
      @channels = Array.new(NUM_CHANNELS) { Channel.new }
      @dpcr = 0x0765_4321  # Default: all channels enabled with default priorities
      @dicr = 0
      @master_flag_latched = false  # Has IRQ#3 fired for the current rising edge?
    end

    # Register access (offset from 0x1F801080)
    def read(offset)
      if offset < 0x70
        # Channel registers
        channel_num = offset >> 4
        reg = offset & 0xF

        return 0 if channel_num >= NUM_CHANNELS

        channel = @channels[channel_num]
        case reg
        when 0x0 then channel.base_addr
        when 0x4 then channel.block_ctrl
        when 0x8 then channel.channel_ctrl
        else 0
        end
      elsif offset == 0x70
        @dpcr
      elsif offset == 0x74
        @dicr
      else
        0
      end
    end

    def write(offset, value)
      if offset < 0x70
        # Channel registers
        channel_num = offset >> 4
        reg = offset & 0xF

        return if channel_num >= NUM_CHANNELS

        channel = @channels[channel_num]
        case reg
        when 0x0
          channel.base_addr = value & 0x00FF_FFFC  # Word-aligned, 24-bit
        when 0x4
          channel.block_ctrl = value
        when 0x8
          # OTC (channel 6) has hard-wired CHCR bits: only bits 24, 28, 30
          # are writable, and bit 1 (Memory Address Step = backward) always
          # reads as 1. Verified against ps1-tests/dma/otc-test.
          if channel_num == OTC
            channel.channel_ctrl = (value & 0x5100_0000) | 0x0000_0002
          else
            channel.channel_ctrl = value
          end
        end
      elsif offset == 0x70
        @dpcr = value
      elsif offset == 0x74
        write_dicr(value)
      end
    end

    def write_dicr(value)
      # Bits 0-5: Unknown/unused
      # Bit 15: Force IRQ
      # Bits 16-22: IRQ enable for channels 0-6
      # Bit 23: Master IRQ enable
      # Bits 24-30: IRQ flags for channels 0-6 (write 1 to acknowledge)
      # Bit 31: Master IRQ flag (read-only)

      # Acknowledge flags by writing 1
      ack = value & DICR_IRQ_FLAGS
      @dicr &= ~ack

      # Update writable bits (preserve flags that weren't acknowledged)
      @dicr = (@dicr & DICR_IRQ_FLAGS) |
              (value & 0x00FF_803F)

      # Update master flag
      update_master_flag
    end

    def update_master_flag
      # PSX semantics: IRQ#3 fires on the rising edge of master-flag (bit 31).
      # The master flag itself is "calculated" from current state. We expose it
      # as DICR bit 31 for software to read, and use an internal latch so the
      # IRQ fires exactly once per rising edge — until the condition goes false
      # again (BIOS acks channel flags or clears master enable).
      force = (@dicr & DICR_FORCE_IRQ) != 0
      master_enable = (@dicr & DICR_IRQ_MASTER) != 0
      flags = (@dicr >> 24) & 0x7F
      enables = (@dicr >> 16) & 0x7F
      master = force || (master_enable && (flags & enables) != 0)

      if master
        @dicr |= DICR_IRQ_MASTER_FLAG
        unless @master_flag_latched
          @master_flag_latched = true
          @interrupts&.request(Interrupts::IRQ_DMA)
        end
      else
        @dicr &= ~DICR_IRQ_MASTER_FLAG
        @master_flag_latched = false
      end
    end

    def channel_enabled?(n)
      # Check DPCR enable bit for channel
      # Each channel has 4 bits in DPCR, bit 3 of each is enable
      (@dpcr >> (n * 4 + 3)) & 1 == 1
    end

    def set_irq_flag(channel)
      # Per Nocash: per-channel IRQ flag is set on completion only when the
      # corresponding per-channel IRQ enable (bits 16-22) is also set.
      return unless ((@dicr >> (16 + channel)) & 1) == 1
      @dicr |= (1 << (24 + channel))
      update_master_flag
    end

    # Execute pending DMA transfers
    # Returns true if any transfer was performed
    def tick(memory, gpu: nil)
      NUM_CHANNELS.times do |n|
        next unless channel_enabled?(n)
        sync_mode = (@channels[n].channel_ctrl >> 9) & 0x3
        # Only OTC needs an explicit manual trigger in SyncMode 0; channels
        # backed by a device (GPU/SPU/...) start on BUSY alone.
        needs_trigger = (n == OTC) && (sync_mode == SYNC_MANUAL)
        next unless @channels[n].active?(needs_trigger: needs_trigger)

        case n
        when GPU
          transfer_gpu(memory, gpu)
        when SPU
          transfer_spu(memory)
        when OTC
          transfer_otc(memory)
        # Other channels can be added as needed
        end
      end
    end

    private

    def transfer_gpu(memory, gpu)
      channel = @channels[GPU]

      case channel.sync_mode
      when SYNC_MANUAL, SYNC_REQUEST
        transfer_gpu_block(memory, gpu, channel)
      when SYNC_LINKED
        transfer_gpu_linked_list(memory, gpu, channel)
      end
    end

    def transfer_gpu_block(memory, gpu, channel)
      # Block transfer to/from GPU
      addr = channel.base_addr
      size = channel.block_size
      size = 0x10000 if size == 0  # 0 means 0x10000 words

      count = channel.block_count
      count = 1 if count == 0

      total = size * count
      step = channel.step

      if channel.direction == :from_ram
        # RAM -> GPU (send commands)
        total.times do
          word = memory.read32(addr & 0x1F_FFFC)
          gpu&.gp0(word)
          addr = (addr + step) & 0xFFFF_FFFF
        end
      else
        # GPU -> RAM (read VRAM)
        total.times do
          word = gpu&.read_data || 0
          memory.write32(addr & 0x1F_FFFC, word)
          addr = (addr + step) & 0xFFFF_FFFF
        end
      end

      channel.finish!
      set_irq_flag(GPU)
    end

    def transfer_gpu_linked_list(memory, gpu, channel)
      # Linked list mode - used for GPU command lists
      # Each node: [header][data...]
      # Header: bits 0-23 = next pointer (or 0xFFFFFF for end), bits 24-31 = word count
      addr = channel.base_addr & 0x1F_FFFC

      loop do
        header = memory.read32(addr)
        word_count = header >> 24

        # Send data words to GPU
        word_count.times do |i|
          word = memory.read32((addr + 4 + i * 4) & 0x1F_FFFC)
          gpu&.gp0(word)
        end

        # Check for end of list
        break if (header & 0x80_0000) != 0

        # Next node
        addr = header & 0x1F_FFFC
      end

      channel.finish!
      set_irq_flag(GPU)
    end

    def transfer_spu(memory)
      channel = @channels[SPU]

      size = channel.block_size
      size = 0x10000 if size == 0
      count = channel.block_count
      count = 1 if count == 0
      total = size * count

      addr = channel.base_addr
      step = channel.step

      if channel.direction == :from_ram
        total.times do
          word = memory.read32(addr & 0x1F_FFFC)
          @spu&.dma_write_word(word)
          addr = (addr + step) & 0xFFFF_FFFF
        end
      else
        total.times do
          word = @spu ? @spu.dma_read_word : 0
          memory.write32(addr & 0x1F_FFFC, word)
          addr = (addr + step) & 0xFFFF_FFFF
        end
      end

      channel.finish!
      set_irq_flag(SPU)
    end

    def transfer_otc(memory)
      # Ordering Table Clear - special reverse-linked-list generator
      # Fills memory with a linked list going backwards
      # Used to initialize GPU ordering tables
      channel = @channels[OTC]

      addr = channel.base_addr & 0x1F_FFFC
      size = channel.block_size
      size = 0x10000 if size == 0

      # Write linked list entries going backwards
      size.times do |i|
        if i == size - 1
          # Last entry - end marker
          memory.write32(addr, 0x00FF_FFFF)
        else
          # Point to previous address
          prev_addr = (addr - 4) & 0x1F_FFFF
          memory.write32(addr, prev_addr)
        end
        addr = (addr - 4) & 0x1F_FFFC
      end

      channel.finish!
      set_irq_flag(OTC)
    end
  end
end
