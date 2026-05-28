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
      attr_accessor :base_addr, :block_ctrl, :channel_ctrl, :busy_cycles
      attr_reader :suspended

      def initialize
        @base_addr = 0
        @block_ctrl = 0
        @channel_ctrl = 0
        @busy_cycles = 0
        @suspended = false
      end

      def active?(needs_trigger: false)
        # Channel is active when Start/Busy bit is set.
        # SyncMode 0 (Manual) without a DRQ-driving device (e.g. OTC) also
        # needs the start-trigger bit. Channels with DRQ (GPU, SPU, CDROM,
        # ...) auto-start when BUSY is set.
        enabled = (@channel_ctrl & CTRL_START_BUSY) != 0
        return false unless enabled
        return false if @suspended
        return false if @busy_cycles.positive?

        if needs_trigger
          (@channel_ctrl & CTRL_START_TRIGGER) != 0
        else
          true
        end
      end

      # Mark a runaway chain as stuck: the BUSY bit stays set, but tick
      # won't re-enter the transfer. Software typically polls the BUSY
      # bit and aborts the channel by clearing it.
      def suspend!
        @suspended = true
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
    attr_accessor :spu, :cdrom, :memory, :mdec

    def initialize(interrupts: nil, spu: nil, cdrom: nil, mdec: nil)
      @interrupts = interrupts
      @spu = spu
      @cdrom = cdrom
      @mdec = mdec
      @memory = nil  # set by Emulator after Memory is constructed
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
          cancel_pending_completion(channel_num)
          # OTC (channel 6) has hard-wired CHCR bits: only bits 24, 28, 30
          # are writable, and bit 1 (Memory Address Step = backward) always
          # reads as 1. Verified against ps1-tests/dma/otc-test.
          if channel_num == OTC
            channel.channel_ctrl = (value & 0x5100_0000) | 0x0000_0002
          else
            channel.channel_ctrl = value
          end
          # Any new CHCR write clears a prior runaway-chain suspension
          # (software has either re-armed the channel or aborted it).
          channel.instance_variable_set(:@suspended, false)
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
    def tick_cycles(cycles)
      # Retry any CDROM DMA that was waiting for data — the BIOS sets channel 3
      # BUSY before the drive's DRQ goes high, and transfer_cdrom defers when
      # the data FIFO is empty.
      if @memory && cdrom_dma_ready? && channel_enabled?(CDROM) &&
         @channels[CDROM].active?(needs_trigger: false)
        transfer_cdrom(@memory)
      end

      if @memory && @mdec&.data_out_available? && channel_enabled?(MDEC_OUT) &&
         @channels[MDEC_OUT].active?(needs_trigger: false)
        transfer_mdec_out(@memory)
      end

      return unless @pending_completions && !@pending_completions.empty?

      @pending_completions.reject! do |n|
        ch = @channels[n]
        ch.busy_cycles -= cycles
        if ch.busy_cycles <= 0
          ch.finish!
          set_irq_flag(n)
          true
        else
          false
        end
      end
    end

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
        when CDROM
          transfer_cdrom(memory)
        when OTC
          transfer_otc(memory)
        when MDEC_IN
          transfer_mdec_in(memory)
        when MDEC_OUT
          transfer_mdec_out(memory)
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

      schedule_completion(GPU, gpu_dma_completion_cycles(channel, total))
    end

    # Cap on linked-list chain walks so a self-referential chain (the case
    # tested by ps1-tests dma/chain-looping) can't hang the emulator. 64K
    # nodes is far beyond any real workload — a frame's worth of GP0
    # commands fits in well under 10K nodes.
    MAX_CHAIN_NODES = 65_536

    def transfer_gpu_linked_list(memory, gpu, channel)
      # Linked list mode for GPU command lists. Each node:
      #   header word: bits 0..23 = next pointer, bit 23 = end-of-list,
      #                bits 24..31 = word count
      #   followed by `word_count` data words forwarded to GP0.
      addr = channel.base_addr & 0x1F_FFFC
      reached_end = false

      MAX_CHAIN_NODES.times do
        header = memory.read32(addr)
        word_count = header >> 24

        word_count.times do |i|
          word = memory.read32((addr + 4 + i * 4) & 0x1F_FFFC)
          gpu&.gp0(word)
        end

        # Bit 23 of the next-address field marks end-of-chain (any addr
        # with bit 23 set, conventionally 0x00FFFFFF).
        if (header & 0x80_0000) != 0
          reached_end = true
          break
        end

        addr = header & 0x1F_FFFC
      end

      if reached_end
        channel.finish!
        set_irq_flag(GPU)
      else
        # Self-referential / runaway chain. Real hardware would walk
        # forever; we walked MAX_CHAIN_NODES nodes for safety. Leave
        # the channel BUSY without raising IRQ so software sees the
        # same "stuck" signature (ps1-tests dma/chain-looping checks
        # finished=false, irq=false on a self-ref chain).
        channel.suspend!
      end
    end

    # CD-ROM data FIFO -> RAM. The BIOS configures channel 3 in SyncMode 1
    # (request-sync block transfer). Real hardware doesn't drain until the
    # drive's DRQ goes high (sector data ready); if we transfer eagerly when
    # BUSY is set the BIOS reads zeros and falls back to LBA 0. So if the
    # CDROM's data FIFO isn't populated yet, leave the channel BUSY and let
    # `tick_cycles` retry once the CDROM tick fires its INT1.
    def transfer_cdrom(memory)
      channel = @channels[CDROM]
      return false unless cdrom_dma_ready?

      size = channel.block_size
      size = 0x10000 if size == 0
      count = channel.block_count
      count = 1 if count == 0
      total = size * count

      addr = channel.base_addr
      step = channel.step
      transferred = 0

      while transferred < total && cdrom_dma_ready?
        word = @cdrom.dma_read_word
        memory.write32(addr & 0x1F_FFFC, word)
        addr = (addr + step) & 0xFFFF_FFFF
        transferred += 1
      end

      remaining = total - transferred
      if remaining.positive?
        channel.base_addr = addr & 0x00FF_FFFC
        if remaining <= size
          channel.block_ctrl = (1 << 16) | remaining
        else
          remaining_blocks = (remaining + size - 1) / size
          channel.block_ctrl = (remaining_blocks << 16) | size
        end
        return true
      end

      channel.finish!
      set_irq_flag(CDROM)
      true
    end

    def cdrom_dma_ready?
      return false unless @cdrom
      return @cdrom.dma_data_ready? if @cdrom.respond_to?(:dma_data_ready?)

      @cdrom.data_fifo_has_data?
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

      # Real SPU DMA is ~16 cycles per word; defer the BUSY clear so that
      # cycle-counting tests (ps1-tests spu/memory-transfer) see a non-zero
      # wait. Data already in place — only the completion flag waits.
      schedule_completion(SPU, total * 16)
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

      # OTC is RAM-only; finish synchronously so the existing otc-test asserts
      # still hold (they check CHCR after a single write, with no cycle gap).
      channel.finish!
      set_irq_flag(OTC)
    end

    # RAM -> MDEC0 (channel 0). The game sets up SyncMode 1 (request-sync)
    # and we drain `block_size * block_count` words, each fed into the
    # decoder's data-in port. Output never appears until phase 3 ships a
    # real IDCT; phase 2 just makes sure the ingress path completes
    # without hanging.
    def transfer_mdec_in(memory)
      channel = @channels[MDEC_IN]
      size  = channel.block_size; size  = 0x10000 if size.zero?
      count = channel.block_count; count = 1     if count.zero?
      total = size * count
      addr  = channel.base_addr
      step  = channel.step

      total.times do
        word = memory.read32(addr & 0x1F_FFFC)
        @mdec&.write32_data(word)
        addr = (addr + step) & 0xFFFF_FFFF
      end

      channel.finish!
      set_irq_flag(MDEC_IN)
    end

    # MDEC0 -> RAM (channel 1). DuckStation starts a request-mode block when
    # MDEC DRQ is asserted, reads whatever words are currently in the output
    # FIFO, and advances the DMA block even if the FIFO empties before the
    # full block size. Under-read destination words are left untouched.
    def transfer_mdec_out(memory)
      channel = @channels[MDEC_OUT]
      return unless @mdec&.data_out_available?

      size  = channel.block_size; size  = 0x10000 if size.zero?
      count = channel.block_count; count = 1     if count.zero?
      addr  = channel.base_addr
      step  = channel.step

      case channel.sync_mode
      when SYNC_REQUEST
        blocks_remaining = count

        while blocks_remaining.positive? && @mdec&.data_out_available?
          block_addr = addr
          transferred = 0
          while transferred < size && @mdec&.data_out_available?
            word = @mdec.read32_data
            memory.write32(block_addr & 0x1F_FFFC, word)
            block_addr = (block_addr + step) & 0xFFFF_FFFF
            transferred += 1
          end

          addr = (addr + (step * size)) & 0xFFFF_FFFF
          blocks_remaining -= 1
        end

        if blocks_remaining.positive?
          channel.base_addr = addr & 0x00FF_FFFC
          channel.block_ctrl = (blocks_remaining << 16) | size
          return true
        end
      else
        total = size * count
        transferred = 0
        while transferred < total && @mdec&.data_out_available?
          word = @mdec.read32_data
          memory.write32(addr & 0x1F_FFFC, word)
          addr = (addr + step) & 0xFFFF_FFFF
          transferred += 1
        end
      end

      channel.finish!
      set_irq_flag(MDEC_OUT)
      true
    end

    # Mark a channel as still busy for `cycles` more CPU cycles, so callers
    # polling CHCR.BUSY see a non-zero wait. Called by transfers that want to
    # model device-side latency. Resolved by `tick_cycles`.
    def schedule_completion(channel_num, cycles)
      if cycles <= 0
        @channels[channel_num].finish!
        set_irq_flag(channel_num)
        return
      end

      @channels[channel_num].busy_cycles = cycles
      @pending_completions ||= []
      @pending_completions << channel_num unless @pending_completions.include?(channel_num)
    end

    def cancel_pending_completion(channel_num)
      @channels[channel_num].busy_cycles = 0
      @pending_completions&.delete(channel_num)
    end

    def dma_ram_cycles(word_count)
      word_count + ((word_count + 15) / 16)
    end

    def gpu_dma_completion_cycles(channel, word_count)
      return 0 unless channel.sync_mode == SYNC_MANUAL && (channel.channel_ctrl & CTRL_CHOPPING) != 0

      cycles = dma_ram_cycles(word_count)
      dma_window = (channel.channel_ctrl >> 16) & 0x7
      cpu_window = (channel.channel_ctrl >> 20) & 0x7
      blocks = word_count >> dma_window
      chop_delay = [(1 << cpu_window) * blocks, 500].min
      cycles += chop_delay if word_count > 4 && chop_delay > 1
      cycles
    end

  end
end
