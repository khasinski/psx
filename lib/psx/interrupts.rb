# frozen_string_literal: true

module PSX
  # Interrupt Controller
  # Manages hardware interrupts via I_STAT and I_MASK registers
  class Interrupts
    # Interrupt bits
    IRQ_VBLANK    = 0x001  # Vertical blank
    IRQ_GPU       = 0x002  # GPU ready
    IRQ_CDROM     = 0x004  # CD-ROM
    IRQ_DMA       = 0x008  # DMA transfer complete
    IRQ_TIMER0    = 0x010  # Timer 0
    IRQ_TIMER1    = 0x020  # Timer 1
    IRQ_TIMER2    = 0x040  # Timer 2
    IRQ_CONTROLLER = 0x080 # Controller/memory card
    IRQ_SIO       = 0x100  # Serial I/O
    IRQ_SPU       = 0x200  # Sound
    IRQ_LIGHTPEN  = 0x400  # Lightpen (directly active)

    attr_reader :stat, :mask

    def initialize
      @stat = 0  # I_STAT - interrupt status (active interrupts)
      @mask = 0  # I_MASK - interrupt mask (enabled interrupts)
    end

    def read_stat
      @stat
    end

    def read_mask
      @mask
    end

    def write_stat(value)
      # Writing to I_STAT acknowledges (clears) interrupts.
      # On PSX: write 0 to a bit clears it (ack), write 1 leaves it unchanged.
      @stat &= value
    end

    def write_mask(value)
      @mask = value & 0x7FF
    end

    # Request an interrupt
    def request(irq)
      @stat |= irq
    end

    # Check if any unmasked interrupt is pending
    def pending?
      (@stat & @mask) != 0
    end

    # Trigger VBlank interrupt
    def vblank!
      request(IRQ_VBLANK)
    end

    # Trigger GPU interrupt
    def gpu!
      request(IRQ_GPU)
    end

    # Trigger DMA interrupt
    def dma!
      request(IRQ_DMA)
    end

    # Trigger timer interrupt
    def timer!(n)
      case n
      when 0 then request(IRQ_TIMER0)
      when 1 then request(IRQ_TIMER1)
      when 2 then request(IRQ_TIMER2)
      end
    end
  end
end
