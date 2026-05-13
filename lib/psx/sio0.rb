# frozen_string_literal: true

module PSX
  # SIO0: Controller and memory-card serial port.
  #
  # The BIOS uses this to probe slots 1 and 2 every VBlank ("PadAutoPolling"):
  # it pulls /JOYn low via JOY_CTRL, sends a series of bytes through JOY_DATA,
  # and waits for the device to /ACK each byte. The /ACK signal latches as
  # JOY_STAT bit 9 and raises IRQ_CONTROLLER (I_STAT bit 7). If no /ACK
  # arrives within ~81 polling iterations the BIOS treats the slot as empty
  # and moves on.
  #
  # We model just enough of this to convince the BIOS that a digital pad is
  # connected in slot 1 (so we get past PadAutoPolling and into the shell)
  # and that nothing is in slot 2 / memory-card port (so the BIOS doesn't
  # wait for an empty memcard to respond). The host SDL keyboard feeds the
  # button state through a callback supplied at construction time.
  class SIO0
    # JOY_STAT (0x1F801044) bits
    STAT_TX_READY_1   = 1 << 0  # TX FIFO has room
    STAT_RX_FIFO_NE   = 1 << 1  # RX FIFO not empty
    STAT_TX_READY_2   = 1 << 2  # No active transfer / TX done
    STAT_RX_PARITY    = 1 << 3
    STAT_ACK_INPUT    = 1 << 7  # /ACK input level (0=device pulling low)
    STAT_IRQ_REQUEST  = 1 << 9

    # JOY_CTRL (0x1F80104A) bits
    CTRL_TXEN         = 1 << 0
    CTRL_JOYN_OUTPUT  = 1 << 1  # /JOYn output level (1 = device selected)
    CTRL_RXEN         = 1 << 2
    CTRL_ACK          = 1 << 4  # write 1 to reset IRQ + parity bits
    CTRL_RESET        = 1 << 6  # write 1 to reset entire SIO state
    CTRL_RX_INT_EN    = 1 << 11
    CTRL_TX_INT_EN    = 1 << 10
    CTRL_ACK_INT_EN   = 1 << 12
    CTRL_SLOT         = 1 << 13 # 0 = slot 1, 1 = slot 2

    # Digital pad protocol response bytes
    DIGITAL_PAD_IDHI  = 0x41
    PAD_READY_BYTE    = 0x5A

    def initialize(interrupts: nil, controller_state: -> { 0xFFFF })
      @interrupts = interrupts
      @controller_state = controller_state
      reset_all
    end

    def reset_all
      @ctrl   = 0
      @mode   = 0
      @baud   = 0
      @rx     = []
      @irq    = false   # JOY_STAT bit 9 (and source of IRQ_CONTROLLER)
      @device_step = 0  # 0 = waiting for select byte
      @pending_ack_cycles = nil  # countdown before /ACK pulse fires
    end

    # Drive the /ACK timing. The BIOS clears I_STAT bit 7 right after writing
    # JOY_DATA and only then enters the polling loop, so we must wait a beat
    # before raising IRQ_CONTROLLER -- otherwise the BIOS clear wipes our IRQ
    # and the poll spins until timeout.
    def tick(cycles)
      return unless @pending_ack_cycles
      @pending_ack_cycles -= cycles
      return if @pending_ack_cycles > 0
      @pending_ack_cycles = nil
      @irq = true
      @interrupts&.request(Interrupts::IRQ_CONTROLLER)
    end

    # --- Bus interface -----------------------------------------------------

    # Reads are byte-addressable; widen as needed for 16/32-bit accesses.
    def read8(offset)
      case offset
      when 0x40 then pop_rx
      when 0x41, 0x42, 0x43 then 0
      when 0x44 then status & 0xFF
      when 0x45 then (status >> 8) & 0xFF
      when 0x46 then (status >> 16) & 0xFF
      when 0x47 then (status >> 24) & 0xFF
      when 0x48 then @mode & 0xFF
      when 0x49 then (@mode >> 8) & 0xFF
      when 0x4A then @ctrl & 0xFF
      when 0x4B then (@ctrl >> 8) & 0xFF
      when 0x4E then @baud & 0xFF
      when 0x4F then (@baud >> 8) & 0xFF
      else 0
      end
    end

    def read16(offset)
      case offset
      when 0x40 then pop_rx
      when 0x44 then status & 0xFFFF
      when 0x46 then (status >> 16) & 0xFFFF
      when 0x48 then @mode
      when 0x4A then @ctrl
      when 0x4E then @baud
      else 0
      end
    end

    def read32(offset)
      case offset
      when 0x40 then pop_rx
      when 0x44 then status
      when 0x48 then @mode | (@ctrl << 16)
      when 0x4C then @baud # unaligned but harmless
      else 0
      end
    end

    def write8(offset, value)
      case offset
      when 0x40 then transmit(value & 0xFF)
      when 0x4A then write_ctrl((@ctrl & 0xFF00) | (value & 0xFF))
      when 0x4B then write_ctrl((@ctrl & 0x00FF) | ((value & 0xFF) << 8))
      end
    end

    def write16(offset, value)
      case offset
      when 0x40 then transmit(value & 0xFF)
      when 0x48 then @mode = value & 0xFFFF
      when 0x4A then write_ctrl(value & 0xFFFF)
      when 0x4E then @baud = value & 0xFFFF
      end
    end

    def write32(offset, value)
      case offset
      when 0x40 then transmit(value & 0xFF)
      when 0x48
        @mode = value & 0xFFFF
        write_ctrl((value >> 16) & 0xFFFF)
      when 0x4C then @baud = value & 0xFFFF
      end
    end

    # --- Status / RX / TX --------------------------------------------------

    # Read-side JOY_STAT word.
    def status
      s = STAT_TX_READY_1 | STAT_TX_READY_2 | STAT_ACK_INPUT
      s |= STAT_RX_FIFO_NE unless @rx.empty?
      s |= STAT_IRQ_REQUEST if @irq
      s
    end

    private

    def pop_rx
      return 0xFF if @rx.empty?
      @rx.shift
    end

    # BIOS writes a TX byte: we look up the device response and (if a device
    # is "answering") drop it into the RX FIFO and raise the ACK interrupt.
    def transmit(byte)
      return unless (@ctrl & (CTRL_TXEN | CTRL_JOYN_OUTPUT)) == (CTRL_TXEN | CTRL_JOYN_OUTPUT)

      # Only slot 1 has a device; slot 2 stays silent (no /ACK -> BIOS timeout)
      if (@ctrl & CTRL_SLOT) != 0
        @rx.push(0xFF)
        return
      end

      response = device_step_byte(byte)
      @rx.push(response & 0xFF)

      # Schedule the /ACK pulse a few hundred cycles into the future. The
      # BIOS polls I_STAT bit 7 in a tight loop after issuing the TX, but it
      # first clears bit 7 between the TX and the poll -- firing immediately
      # would be wiped out by that clear, leaving the poll to spin forever.
      if (@ctrl & CTRL_ACK_INT_EN) != 0 && !@ack_suppressed
        @pending_ack_cycles = 500
      end
    end

    # Digital-pad protocol state machine.
    #   step 0: TX 0x01  -> 0xFF (high-Z), /ACK
    #   step 1: TX 0x42  -> 0x41 (digital id), /ACK
    #   step 2: TX 0x00  -> 0x5A (ready),     /ACK
    #   step 3: TX 0x00  -> buttons low,      /ACK
    #   step 4: TX 0x00  -> buttons high,     no /ACK (last byte -> BIOS knows end)
    # Memory-card probe (TX 0x81 in step 0) aborts after the first byte so
    # the BIOS sees "no memcard" via the no-/ACK timeout.
    def device_step_byte(tx)
      @ack_suppressed = false
      case @device_step
      when 0
        if tx == 0x01
          @device_step = 1
          0xFF
        else
          # TX 0x81 (memcard) or any other byte -> deselect, no further /ACK
          @device_step = 0
          @ack_suppressed = true
          0xFF
        end
      when 1
        @device_step = 2
        DIGITAL_PAD_IDHI
      when 2
        @device_step = 3
        PAD_READY_BYTE
      when 3
        @device_step = 4
        buttons & 0xFF
      when 4
        # Last byte of the transaction; no /ACK keeps the BIOS from polling
        # for a sixth byte.
        @device_step = 0
        @ack_suppressed = true
        (buttons >> 8) & 0xFF
      else
        @device_step = 0
        @ack_suppressed = true
        0xFF
      end
    end

    def write_ctrl(value)
      prev = @ctrl
      @ctrl = value & 0xFFFF

      if (value & CTRL_RESET) != 0
        # Reset clears most state but the BIOS expects to be able to read
        # JOY_STAT cleanly afterwards.
        @rx.clear
        @irq = false
        @device_step = 0
        @mode = 0
        @baud = 0
      end

      if (value & CTRL_ACK) != 0
        @irq = false
      end

      # /JOYn rising edge -> a fresh transaction begins (BIOS will TX next).
      if (prev & CTRL_JOYN_OUTPUT) == 0 && (@ctrl & CTRL_JOYN_OUTPUT) != 0
        @device_step = 0
        @rx.clear
      end

      # /JOYn falling edge -> deselect, reset protocol state.
      if (prev & CTRL_JOYN_OUTPUT) != 0 && (@ctrl & CTRL_JOYN_OUTPUT) == 0
        @device_step = 0
      end
    end

    def buttons
      state = @controller_state.call
      state & 0xFFFF
    rescue StandardError
      0xFFFF
    end
  end
end
