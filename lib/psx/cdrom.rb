# frozen_string_literal: true

module PSX
  # Minimal CD-ROM controller stub.
  #
  # Enough to convince the BIOS that there's a CD subsystem present with no
  # disc inserted, so it proceeds to the shell screen. Handles the commands
  # the BIOS issues during boot: GetStat, Init, GetID, Setmode, Test, etc.
  #
  # We don't model timing accurately. Responses are queued and delivered one
  # per tick (called from the emulator's frame loop), respecting that the
  # previous IRQ must be acknowledged and the previous response FIFO drained
  # before the next response shows up.
  class CDROM
    # Status register (0x1F801800 read) bits
    STAT_INDEX_MASK              = 0x03
    STAT_ADPCM_BUSY              = 0x04
    STAT_PARAMETER_FIFO_EMPTY    = 0x08
    STAT_PARAMETER_FIFO_NOT_FULL = 0x10
    STAT_RESPONSE_FIFO_NOT_EMPTY = 0x20
    STAT_DATA_FIFO_NOT_EMPTY     = 0x40
    STAT_BUSY                    = 0x80

    # "stat" byte returned in command responses.
    # Bit 4 = shell open (we say closed); bit 0 = error.
    # We default to 0x02 (motor on, no error, no disc seek done) for no-disc.
    DEFAULT_STAT = 0x02

    def initialize(interrupts:)
      @interrupts = interrupts
      reset
    end

    def reset
      @index = 0
      @parameters = []
      @response  = []
      @irq_enable = 0
      @irq_flags  = 0          # bits 0-2 = pending INT type (0..7)
      @pending = []            # [[int_type, [bytes...]], ...]
      @stat = DEFAULT_STAT
    end

    # --- Bus interface ------------------------------------------------------

    def read8(reg)
      case reg & 3
      when 0 then status
      when 1
        # Response FIFO
        v = @response.shift || 0
        v & 0xFF
      when 2
        # Data FIFO (no data, just return 0)
        0
      when 3
        case @index
        when 0, 2 then @irq_enable | 0xE0
        when 1, 3 then @irq_flags | 0xE0
        end
      end
    end

    def write8(reg, value)
      v = value & 0xFF
      case reg & 3
      when 0
        @index = v & 3
      when 1
        case @index
        when 0 then execute_command(v)
        # other indices: audio map / right CD audio routing — ignore
        end
      when 2
        case @index
        when 0
          @parameters.push(v) if @parameters.size < 16
        when 1
          @irq_enable = v & 0x1F
        # 2/3 = audio routing — ignore
        end
      when 3
        case @index
        when 0
          # Request register: bit 7 BFRD enables data buffer read; bit 5 SMEN.
          # Both unused by our stub.
        when 1
          # Ack IRQ flags and optionally reset parameter FIFO (bit 6).
          @irq_flags &= ~(v & 0x1F)
          @parameters.clear if (v & 0x40) != 0
        # 2/3 = audio volume apply — ignore
        end
      end
    end

    # Advance one step in the response queue. Call this periodically (e.g.
    # once per VBlank). One delivery per call: a response only appears once
    # the previous one has been acknowledged.
    def tick
      return if @pending.empty?
      return if @irq_flags != 0           # previous IRQ not yet acknowledged
      return if !@response.empty?         # previous response not yet drained

      type, data = @pending.shift
      @response.concat(data)
      @irq_flags = type & 0x07
      @interrupts.request(Interrupts::IRQ_CDROM) if (@irq_enable & @irq_flags) != 0
    end

    private

    def status
      s = @index & STAT_INDEX_MASK
      s |= STAT_PARAMETER_FIFO_EMPTY    if @parameters.empty?
      s |= STAT_PARAMETER_FIFO_NOT_FULL if @parameters.size < 16
      s |= STAT_RESPONSE_FIFO_NOT_EMPTY unless @response.empty?
      s
    end

    def execute_command(cmd)
      case cmd
      when 0x01 # Getstat
        queue(3, [@stat])
      when 0x02 # Setloc (MM, SS, FF)
        @parameters.clear
        queue(3, [@stat])
      when 0x06 # ReadN
        queue(3, [@stat])
        queue(5, [0x11, 0x80])  # no disc -> error
      when 0x07 # MotorOn
        queue(3, [@stat])
        queue(2, [@stat])
      when 0x08 # Stop
        queue(3, [@stat])
        queue(2, [@stat])
      when 0x09 # Pause
        queue(3, [@stat])
        queue(2, [@stat])
      when 0x0A # Init
        queue(3, [@stat])
        queue(2, [@stat])
      when 0x0B # Mute
        queue(3, [@stat])
      when 0x0C # Demute
        queue(3, [@stat])
      when 0x0D # Setfilter
        queue(3, [@stat])
      when 0x0E # Setmode
        queue(3, [@stat])
      when 0x0F # Getparam
        queue(3, [@stat, 0x00, 0x00, 0x00])
      when 0x10 # GetlocL
        queue(3, [0, 0, 0, 0, 0, 0, 0, 0])
      when 0x11 # GetlocP
        queue(3, [1, 1, 0, 0, 0, 0, 0, 0])
      when 0x13 # GetTN (number of tracks)
        queue(3, [@stat, 0x01, 0x01])
      when 0x14 # GetTD
        queue(3, [@stat, 0x00, 0x02])
      when 0x15 # SeekL
        queue(3, [@stat])
        queue(2, [@stat])
      when 0x16 # SeekP
        queue(3, [@stat])
        queue(2, [@stat])
      when 0x19 # Test
        sub = @parameters.shift
        case sub
        when 0x20 # Get BIOS date/version
          queue(3, [0x94, 0x09, 0x19, 0xC0])
        else
          queue(3, [@stat])
        end
      when 0x1A # GetID
        queue(3, [@stat])
        queue(5, [0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) # no disc
      when 0x1B # ReadS
        queue(3, [@stat])
        queue(5, [0x11, 0x80])
      when 0x1E # ReadTOC
        queue(3, [@stat])
        queue(2, [@stat])
      else
        queue(3, [@stat])  # default ack to keep BIOS moving
      end
      @parameters.clear unless cmd == 0x19  # Test consumes its own params
    end

    def queue(int_type, data)
      @pending.push([int_type, data])
    end
  end
end
