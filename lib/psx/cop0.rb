# frozen_string_literal: true

module PSX
  # Coprocessor 0 - System Control
  # Handles exceptions, interrupts, and memory management
  class COP0
    # Register indices
    BPC      = 3   # Breakpoint on execute
    BDA      = 5   # Breakpoint on data access
    JUMPDEST = 6   # Jump destination (for branch delay debugging)
    DCIC     = 7   # Breakpoint control
    BADVADDR = 8   # Bad virtual address
    BDAM     = 9   # Data access breakpoint mask
    BPCM     = 11  # Execute breakpoint mask
    SR       = 12  # Status register
    CAUSE    = 13  # Exception cause
    EPC      = 14  # Exception program counter
    PRID     = 15  # Processor ID

    # Status register bits
    SR_IEC  = 0x01       # Interrupt Enable Current
    SR_KUC  = 0x02       # Kernel/User Mode Current (0=kernel)
    SR_IEP  = 0x04       # Interrupt Enable Previous
    SR_KUP  = 0x08       # Kernel/User Mode Previous
    SR_IEO  = 0x10       # Interrupt Enable Old
    SR_KUO  = 0x20       # Kernel/User Mode Old
    SR_IM   = 0xFF00     # Interrupt Mask (bits 8-15)
    SR_ISC  = 0x1_0000   # Isolate Cache
    SR_SWC  = 0x2_0000   # Swap Caches
    SR_PZ   = 0x4_0000   # Parity Zero
    SR_CM   = 0x8_0000   # Cache Miss
    SR_PE   = 0x10_0000  # Parity Error
    SR_TS   = 0x20_0000  # TLB Shutdown
    SR_BEV  = 0x40_0000  # Boot Exception Vectors
    SR_RE   = 0x200_0000 # Reverse Endianness
    SR_CU0  = 0x1000_0000  # COP0 Enable
    SR_CU1  = 0x2000_0000  # COP1 Enable (no FPU on PSX, but enable bit exists)
    SR_CU2  = 0x4000_0000  # COP2 (GTE) Enable
    SR_CU3  = 0x8000_0000  # COP3 Enable

    # Exception codes (for CAUSE register bits 2-6)
    EXC_INT   = 0x00  # Interrupt
    EXC_MOD   = 0x01  # TLB modification
    EXC_TLBL  = 0x02  # TLB load
    EXC_TLBS  = 0x03  # TLB store
    EXC_ADEL  = 0x04  # Address error (load/fetch)
    EXC_ADES  = 0x05  # Address error (store)
    EXC_IBE   = 0x06  # Bus error (instruction fetch)
    EXC_DBE   = 0x07  # Bus error (data load/store)
    EXC_SYS   = 0x08  # Syscall
    EXC_BP    = 0x09  # Breakpoint
    EXC_RI    = 0x0A  # Reserved instruction
    EXC_CPU   = 0x0B  # Coprocessor unusable
    EXC_OV    = 0x0C  # Arithmetic overflow

    # Interrupt bits in CAUSE (bits 8-15, matches SR mask)
    IRQ_SOFTWARE0 = 0x0100
    IRQ_SOFTWARE1 = 0x0200
    IRQ_HARDWARE  = 0x0400  # External hardware interrupt (active when I_STAT & I_MASK != 0)

    attr_reader :regs

    def initialize
      @regs = Array.new(32, 0)
      @regs[PRID] = 0x0000_0002  # R3000A processor ID
    end

    def read(reg)
      @regs[reg]
    end

    def write(reg, value)
      case reg
      when SR
        # Most bits are writable
        @regs[SR] = value & 0xF4C7_9C3F
      when CAUSE
        # Only software interrupt bits (8-9) are writable
        @regs[CAUSE] = (value & 0x0300) | (@regs[CAUSE] & ~0x0300)
      when PRID
        # Read-only
      else
        @regs[reg] = value
      end
    end

    def sr
      @regs[SR]
    end

    def sr=(value)
      write(SR, value)
    end

    def cause
      @regs[CAUSE]
    end

    def epc
      @regs[EPC]
    end

    def cache_isolated?
      (@regs[SR] & SR_ISC) != 0
    end

    def bev?
      (@regs[SR] & SR_BEV) != 0
    end

    def interrupts_enabled?
      (@regs[SR] & SR_IEC) != 0
    end

    def interrupt_pending?
      # Check if any unmasked interrupt is pending
      return false unless interrupts_enabled?

      mask = (@regs[SR] >> 8) & 0xFF
      pending = (@regs[CAUSE] >> 8) & 0xFF
      (mask & pending) != 0
    end

    def set_hardware_irq(active)
      if active
        @regs[CAUSE] |= IRQ_HARDWARE
      else
        @regs[CAUSE] &= ~IRQ_HARDWARE
      end
    end

    # Enter exception handler. Returns the exception vector address.
    # `coprocessor` is the COP number (0-3) reported in CAUSE.CE for
    # Coprocessor-Unusable exceptions.
    def enter_exception(code, pc, in_delay_slot: false, bad_addr: nil, coprocessor: nil)
      @regs[EPC] = in_delay_slot ? pc - 4 : pc
      @regs[BADVADDR] = bad_addr if bad_addr

      # CAUSE: preserve interrupt-pending bits, set ExcCode, BD, and CE.
      ce = coprocessor ? ((coprocessor & 0x3) << 28) : 0
      @regs[CAUSE] = (@regs[CAUSE] & 0x0000_FF00) |
                     (code << 2) |
                     ce |
                     (in_delay_slot ? 0x8000_0000 : 0)

      # Shift IE/KU stack: current -> previous -> old.
      mode = @regs[SR] & 0x3F
      @regs[SR] = (@regs[SR] & ~0x3F) | ((mode << 2) & 0x3F)

      bev? ? 0xBFC0_0180 : 0x8000_0080
    end

    # Return from exception (RFE instruction)
    def return_from_exception
      # Shift interrupt enable/kernel mode bits back
      # Old -> Previous -> Current
      mode = @regs[SR] & 0x3F
      @regs[SR] = (@regs[SR] & ~0x0F) | ((mode >> 2) & 0x0F)
    end
  end
end
