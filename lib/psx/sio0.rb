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
  # We model a digital pad and a formatted memory card in slot 1. The host
  # SDL keyboard feeds the button state through a callback supplied at
  # construction time.
  class SIO0
    # JOY_STAT (0x1F801044) bits
    STAT_TX_READY_1   = 1 << 0  # TX FIFO has room
    STAT_RX_FIFO_NE   = 1 << 1  # RX FIFO not empty
    STAT_TX_READY_2   = 1 << 2  # No active transfer / TX done
    STAT_RX_PARITY    = 1 << 3
    STAT_ACK_INPUT    = 1 << 7  # /ACK input level (1=device pulling low)
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

    class MemoryCard
      FRAME_SIZE = 128
      FRAME_COUNT = 1024
      SIZE = FRAME_SIZE * FRAME_COUNT

      attr_reader :data

      def initialize
        @data = Array.new(SIZE, 0xFF)
        format!
        @flag = 0x08
        reset_transfer
      end

      def reset_transfer
        @state = :idle
        @address = 0
        @offset = 0
        @checksum = 0
        @last_byte = 0
      end

      def transfer(byte)
        tx = byte & 0xFF
        response = 0xFF
        ack = false

        case @state
        when :idle
          if tx == 0x81
            response = 0xFF
            ack = true
            @state = :command
          end
        when :command
          response = @flag
          case tx
          when 0x52
            ack = true
            @state = :read_card_id1
          when 0x57
            ack = true
            @state = :write_card_id1
          when 0x53
            ack = true
            @state = :get_id_card_id1
          else
            @state = :idle
          end
        when :read_card_id1
          response, ack, @state = 0x5A, true, :read_card_id2
        when :read_card_id2
          response, ack, @state = 0x5D, true, :read_address_msb
        when :read_address_msb
          @address = ((tx << 8) | (@address & 0x00FF)) & 0x03FF
          response, ack, @state = 0x00, true, :read_address_lsb
        when :read_address_lsb
          @address = ((@address & 0xFF00) | tx) & 0x03FF
          @offset = 0
          response, ack, @state = @last_byte, true, :read_ack1
        when :read_ack1
          response, ack, @state = 0x5C, true, :read_ack2
        when :read_ack2
          response, ack, @state = 0x5D, true, :read_confirm_msb
        when :read_confirm_msb
          response, ack, @state = (@address >> 8) & 0xFF, true, :read_confirm_lsb
        when :read_confirm_lsb
          response, ack, @state = @address & 0xFF, true, :read_data
        when :read_data
          response = @data[@address * FRAME_SIZE + @offset]
          @checksum = @offset.zero? ? (((@address >> 8) & 0xFF) ^ (@address & 0xFF) ^ response) : (@checksum ^ response)
          @offset += 1
          ack = true
          if @offset == FRAME_SIZE
            @offset = 0
            @state = :read_checksum
          end
        when :read_checksum
          response, ack, @state = @checksum & 0xFF, true, :read_end
        when :read_end
          response, ack, @state = 0x47, false, :idle

        when :write_card_id1
          response, ack, @state = 0x5A, true, :write_card_id2
        when :write_card_id2
          response, ack, @state = 0x5D, true, :write_address_msb
        when :write_address_msb
          @address = ((tx << 8) | (@address & 0x00FF)) & 0x03FF
          response, ack, @state = 0x00, true, :write_address_lsb
        when :write_address_lsb
          @address = ((@address & 0xFF00) | tx) & 0x03FF
          @offset = 0
          response, ack, @state = @last_byte, true, :write_data
        when :write_data
          @checksum = @offset.zero? ? (((@address >> 8) & 0xFF) ^ (@address & 0xFF) ^ tx) : (@checksum ^ tx)
          @data[@address * FRAME_SIZE + @offset] = tx
          @flag &= ~0x08
          @offset += 1
          response = @last_byte
          ack = true
          if @offset == FRAME_SIZE
            @offset = 0
            @state = :write_checksum
          end
        when :write_checksum
          response, ack, @state = @last_byte, true, :write_ack1
        when :write_ack1
          response, ack, @state = 0x5C, true, :write_ack2
        when :write_ack2
          response, ack, @state = 0x5D, true, :write_end
        when :write_end
          response, ack, @state = 0x47, false, :idle

        when :get_id_card_id1
          response, ack, @state = 0x5A, true, :get_id_card_id2
        when :get_id_card_id2
          response, ack, @state = 0x5D, true, :get_id_ack1
        when :get_id_ack1
          response, ack, @state = 0x5C, true, :get_id_ack2
        when :get_id_ack2
          response, ack, @state = 0x5D, true, :get_id1
        when :get_id1
          response, ack, @state = 0x04, true, :get_id2
        when :get_id2
          response, ack, @state = 0x00, true, :get_id3
        when :get_id3
          response, ack, @state = 0x00, true, :get_id4
        when :get_id4
          response, ack, @state = 0x80, false, :idle
        end

        @last_byte = tx
        [response & 0xFF, ack]
      end

      private

      def format!
        @data.fill(0xFF)
        write_frame(0, formatted_header_frame)
        (1...16).each do |frame|
          bytes = Array.new(FRAME_SIZE, 0)
          bytes[0] = 0xA0
          bytes[8] = 0xFF
          bytes[9] = 0xFF
          bytes[0x7F] = checksum(bytes)
          write_frame(frame, bytes)
        end
        (16...36).each do |frame|
          bytes = Array.new(FRAME_SIZE, 0)
          bytes[0, 4] = [0xFF, 0xFF, 0xFF, 0xFF]
          bytes[8] = 0xFF
          bytes[9] = 0xFF
          bytes[0x7F] = checksum(bytes)
          write_frame(frame, bytes)
        end
        (36...63).each { |frame| write_frame(frame, Array.new(FRAME_SIZE, 0)) }
        write_frame(63, @data[0, FRAME_SIZE])
      end

      def formatted_header_frame
        bytes = Array.new(FRAME_SIZE, 0)
        bytes[0] = "M".ord
        bytes[1] = "C".ord
        bytes[0x7F] = checksum(bytes)
        bytes
      end

      def write_frame(frame, bytes)
        base = frame * FRAME_SIZE
        FRAME_SIZE.times { |i| @data[base + i] = bytes[i] & 0xFF }
      end

      def checksum(bytes)
        bytes[0...0x7F].reduce(0) { |acc, b| acc ^ b } & 0xFF
      end
    end

    attr_reader :memory_card

    def initialize(interrupts: nil, controller_state: -> { 0xFFFF })
      @interrupts = interrupts
      @controller_state = controller_state
      @memory_card = MemoryCard.new
      reset_all
    end

    def reset_all
      @ctrl   = 0
      @mode   = 0
      @baud   = 0
      @rx     = []
      @irq    = false   # JOY_STAT bit 9 (and source of IRQ_CONTROLLER)
      @device_step = 0  # 0 = waiting for select byte
      @active_device = nil
      @pending_ack_cycles = nil  # countdown before /ACK pulse fires
      @ack_low_cycles = 0
    end

    # Drive the /ACK timing. The BIOS clears I_STAT bit 7 right after writing
    # JOY_DATA and only then enters the polling loop, so we must wait a beat
    # before raising IRQ_CONTROLLER -- otherwise the BIOS clear wipes our IRQ
    # and the poll spins until timeout.
    def tick(cycles)
      ack_started = false
      if @pending_ack_cycles
        @pending_ack_cycles -= cycles
        if @pending_ack_cycles <= 0
          @pending_ack_cycles = nil
          @ack_low_cycles = 250
          ack_started = true
          @irq = true
          @interrupts&.request(Interrupts::IRQ_CONTROLLER)
        end
      end

      if @ack_low_cycles.positive? && !ack_started
        @ack_low_cycles -= cycles
        @ack_low_cycles = 0 if @ack_low_cycles.negative?
      end
    end

    # --- Bus interface -----------------------------------------------------

    # Reads are byte-addressable; widen as needed for 16/32-bit accesses.
    def read8(offset)
      case offset
      when 0x40 then pop_rx
      when 0x41, 0x42, 0x43 then 0
      when 0x44 then read_status & 0xFF
      when 0x45 then (read_status >> 8) & 0xFF
      when 0x46 then (read_status >> 16) & 0xFF
      when 0x47 then (read_status >> 24) & 0xFF
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
      when 0x44 then read_status & 0xFFFF
      when 0x46 then (read_status >> 16) & 0xFFFF
      when 0x48 then @mode
      when 0x4A then @ctrl
      when 0x4E then @baud
      else 0
      end
    end

    def read32(offset)
      case offset
      when 0x40 then pop_rx
      when 0x44 then read_status
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
      s = STAT_TX_READY_1 | STAT_TX_READY_2
      s |= STAT_RX_FIFO_NE unless @rx.empty?
      s |= STAT_ACK_INPUT if @ack_low_cycles.positive?
      s |= STAT_IRQ_REQUEST if @irq
      s
    end

    private

    def read_status
      s = status
      @ack_low_cycles = 0
      s
    end

    def pop_rx
      return 0xFF if @rx.empty?
      @rx.shift
    end

    # BIOS writes a TX byte: we look up the device response and (if a device
    # is "answering") drop it into the RX FIFO and raise the ACK interrupt.
    def transmit(byte)
      return unless (@ctrl & (CTRL_TXEN | CTRL_JOYN_OUTPUT)) == (CTRL_TXEN | CTRL_JOYN_OUTPUT)

      # Only slot 1 has devices; slot 2 stays silent (no /ACK -> BIOS timeout)
      if (@ctrl & CTRL_SLOT) != 0
        @rx.push(0xFF)
        return
      end

      response, ack = device_step_byte(byte)
      @rx.push(response & 0xFF)
      trigger_irq if (@ctrl & CTRL_RX_INT_EN) != 0

      # Schedule the /ACK pulse a few hundred cycles into the future. The
      # BIOS polls I_STAT bit 7 in a tight loop after issuing the TX, but it
      # first clears bit 7 between the TX and the poll -- firing immediately
      # would be wiped out by that clear, leaving the poll to spin forever.
      if (@ctrl & CTRL_ACK_INT_EN) != 0 && ack
        @pending_ack_cycles = 500
      end
    end

    def trigger_irq
      @irq = true
      @interrupts&.request(Interrupts::IRQ_CONTROLLER)
    end

    # Digital-pad protocol state machine.
    #   step 0: TX 0x01  -> 0xFF (high-Z), /ACK
    #   step 1: TX 0x42  -> 0x41 (digital id), /ACK
    #   step 2: TX 0x00  -> 0x5A (ready),     /ACK
    #   step 3: TX 0x00  -> buttons low,      /ACK
    #   step 4: TX 0x00  -> buttons high,     no /ACK (last byte -> BIOS knows end)
    # Memory-card protocol starts with TX 0x81 and is routed to MemoryCard
    # until that device finishes a command with no ACK.
    def device_step_byte(tx)
      if @active_device == :controller
        response, ack = controller_step_byte(tx)
        @active_device = nil unless ack
        return [response, ack]
      elsif @active_device == :memory_card
        response, ack = @memory_card.transfer(tx)
        @active_device = nil unless ack
        return [response, ack]
      end

      if tx == 0x81
        response, ack = @memory_card.transfer(tx)
        @active_device = :memory_card if ack
        return [response, ack]
      end

      response, ack = controller_step_byte(tx)
      @active_device = :controller if ack
      [response, ack]
    end

    def controller_step_byte(tx)
      case @device_step
      when 0
        if tx == 0x01
          @device_step = 1
          [0xFF, true]
        else
          @device_step = 0
          [0xFF, false]
        end
      when 1
        if tx == 0x42
          @device_step = 2
          [DIGITAL_PAD_IDHI, true]
        else
          @device_step = 0
          [0xFF, false]
        end
      when 2
        @device_step = 3
        [PAD_READY_BYTE, true]
      when 3
        @device_step = 4
        [buttons & 0xFF, true]
      when 4
        # Last byte of the transaction; no /ACK keeps the BIOS from polling
        # for a sixth byte.
        @device_step = 0
        [(buttons >> 8) & 0xFF, false]
      else
        @device_step = 0
        [0xFF, false]
      end
    end

    def write_ctrl(value)
      prev = @ctrl
      @ctrl = value & 0xFFFF

      if (value & CTRL_RESET) != 0
        # Reset clears most state but the BIOS expects to be able to read
        # JOY_STAT cleanly afterwards.
        @ctrl = 0
        @rx.clear
        @irq = false
        @pending_ack_cycles = nil
        @ack_low_cycles = 0
        @device_step = 0
        @active_device = nil
        @memory_card.reset_transfer
        @mode = 0
        @baud = 0
      end

      if (value & CTRL_ACK) != 0
        @irq = false
      end

      # /JOYn rising edge -> a fresh transaction begins (BIOS will TX next).
      if (prev & CTRL_JOYN_OUTPUT) == 0 && (@ctrl & CTRL_JOYN_OUTPUT) != 0
        @device_step = 0
        @active_device = nil
        @memory_card.reset_transfer
        @rx.clear
      end

      # /JOYn falling edge -> deselect, reset protocol state.
      if (prev & CTRL_JOYN_OUTPUT) != 0 && (@ctrl & CTRL_JOYN_OUTPUT) == 0
        @device_step = 0
        @active_device = nil
        @memory_card.reset_transfer
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
