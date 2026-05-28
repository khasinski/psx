# frozen_string_literal: true

require_relative "cop0"
require_relative "gte"

module PSX
  class CPU
    class ExecutionError < StandardError; end

    RESET_VECTOR = 0xBFC0_0000  # BIOS entry point

    # Physical address of the A/B/C BIOS jump tables in low RAM
    BIOS_A_DISPATCH = 0x000000A0
    BIOS_B_DISPATCH = 0x000000B0
    BIOS_C_DISPATCH = 0x000000C0
    CALLBACK_TABLE_FLAG = 0x8009_9430
    CALLBACK_TABLE_BASE = 0x8009_9434
    CALLBACK_TABLE_MASK = 0x8009_9460
    CALLBACK_RETURN_SENTINEL = 0x8000_FFFC
    DMA_CALLBACK_TABLE_BASE = 0x8009_A4F8
    RAGE_CDROM_DMA_CALLBACK = 0x8006_CE78
    RAGE_STREAM_QUEUE_BASE_PTR = 0x801E_8AAC
    RAGE_STREAM_DMA_INDEX = 0x801E_6C84
    RAGE_STREAM_QUEUE_ENTRY_SIZE = 32

    attr_reader :pc, :regs, :hi, :lo, :memory, :cop0, :gte, :step_cycles
    attr_accessor :tty_handler

    def pc=(value)
      @pc = value & 0xFFFF_FFFF
      @next_pc = (@pc + 4) & 0xFFFF_FFFF
      @branch_target = nil
      @next_in_delay_slot = false
    end

    def initialize(memory, interrupts: nil)
      @memory = memory
      # Direct references for inlined fast paths so the common-case load,
      # store, and instruction fetch don't pay for a Memory method
      # dispatch on every step.
      @ram_words = memory.ram_words
      @bios_words = memory.bios_words
      @isolated_cache_words = memory.isolated_cache_words
      @region_mask = Memory::REGION_MASK
      @interrupts = interrupts
      @regs = Array.new(32, 0)  # R0 is always 0
      @pc = RESET_VECTOR
      @next_pc = @pc + 4
      @hi = 0
      @lo = 0

      # Coprocessors
      @cop0 = COP0.new
      @gte = GTE.new

      # Delayed load handling
      @load_delay_reg = 0
      @load_delay_value = 0
      @load_delay_commit_reg = 0
      @load_delay_commit_value = 0

      # Branch delay slot tracking. exception() reads @next_in_delay_slot
      # directly to decide whether the current instruction is in a delay
      # slot, so we only need the one "is the next instruction in a delay
      # slot" flag. step's epilogue keeps it accurate: true after a taken
      # branch, false otherwise.
      @branch_target = nil
      @current_pc = @pc

      # Cycles consumed by the most recent step. Defaults to 1 per
      # instruction; loads bump it to reflect the R3000A load-delay slot plus
      # main-RAM access latency (the BIOS code path is mostly uncached). The
      # outer run loop reads this to drive VBlank/timer ticks at roughly the
      # right rate, so wait loops in the BIOS (e.g. VSync) complete before
      # their 0x8000-iteration timeout.
      @step_cycles = 1

      # Whether the previous step set up a branch — i.e. the *current* step
      # is executing a delay-slot instruction. We can't infer this from
      # @next_pc vs @pc+4 because short branches happen to have target ==
      # delay_slot+4; only the branch instruction itself knows.
      @next_in_delay_slot = false
    end

    def step
      @step_cycles = 1
      # Snapshot pre-execute state so a pending interrupt (or any exception
      # raised during this step) records the right EPC/BD. The previous step
      # set @next_in_delay_slot iff it was a taken branch; that means *this*
      # step's instruction is in the delay slot.
      pc = @pc
      next_pc = @next_pc
      @current_pc = pc

      if skip_rage_incomplete_cdrom_dma_callback?(pc)
        self.pc = @regs[31]
        return @step_cycles
      end

      if pc == 0x8000_0080 && @interrupts&.pending? && exception_vector_unusable?
        resume_pc = @cop0.epc
        if service_installed_interrupt_callbacks
          @cop0.return_from_exception
          self.pc = resume_pc
          return @step_cycles
        end
      end

      # Optional TTY hook: intercept BIOS A-table entry so PS-EXE programs
      # built against the standard BIOS putchar/puts functions can be tested
      # without depending on a working CD-ROM/Shell. Returns true when the
      # call has been handled and PC was advanced to the caller.
      if @tty_handler && intercept_bios_call(pc)
        return @step_cycles
      end

      # Fetch instruction. Misaligned PC -> address-error; fetch from a
      # region the bus doesn't service (scratchpad, IRQ, MDEC, timers,
      # JOY/SIO, expansion) -> instruction bus error. Both leave EPC
      # pointing at the offending PC.
      if (pc & 3) != 0
        exception(COP0::EXC_ADEL, bad_addr: pc)
        return @step_cycles
      end
      # Inlined fetch32: the two hot regions (RAM / BIOS ROM) handled here,
      # everything else delegated to Memory#fetch32 which returns nil for
      # a forbidden region.
      phys = pc & @region_mask[(pc >> 29) & 0x7]
      instruction = if phys < 0x0080_0000
                      index = (phys & 0x001F_FFFF) >> 2
                      ram_word = @ram_words[index]
                      ram_word.zero? ? @isolated_cache_words.fetch(index) { ram_word } : ram_word
                    elsif phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
                      @bios_words[(phys - 0x1FC0_0000) >> 2]
                    else
                      @memory.fetch32(pc)
                    end
      if instruction.nil?
        exception(COP0::EXC_IBE, bad_addr: pc)
        return @step_cycles
      end

      # Advance PC (next_pc may have been redirected by a previous branch
      # epilogue, which is exactly what makes the current instruction a
      # delay slot — already captured in @in_delay_slot above).
      @pc = next_pc
      @next_pc = (next_pc + 4) & 0xFFFF_FFFF

      # R3000A load delay: a load result is not visible to the immediately
      # following instruction. Snapshot the pending load now, execute the
      # current instruction with the old register value, then commit below.
      @load_delay_commit_reg = @load_delay_reg
      @load_delay_commit_value = @load_delay_value
      @load_delay_reg = 0

      # Execute (skip NOP). Hot opcodes inlined directly so YJIT can
      # specialize the full fetch -> decode -> op chain in one frame.
      # Cold opcodes still go through their op_* methods.
      if instruction != 0
        opcode = (instruction >> 26) & 0x3F
        case opcode
        when 0x09  # ADDIU
          rs = (instruction >> 21) & 0x1F
          rt = (instruction >> 16) & 0x1F
          imm = instruction & 0xFFFF
          imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
          cancel_load_delay_for(rt)
          @regs[rt] = (@regs[rs] + imm) & 0xFFFF_FFFF if rt != 0
        when 0x23  # LW
          rs = (instruction >> 21) & 0x1F
          rt = (instruction >> 16) & 0x1F
          imm = instruction & 0xFFFF
          imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
          addr = (@regs[rs] + imm) & 0xFFFF_FFFF
          if (addr & 3) != 0
            exception(COP0::EXC_ADEL, bad_addr: addr)
          else
            ph = addr & @region_mask[(addr >> 29) & 0x7]
            val = if ph < 0x0080_0000
                    @ram_words[(ph & 0x001F_FFFF) >> 2]
                  else
                    @memory.read32(addr) & 0xFFFF_FFFF
                  end
            @load_delay_commit_reg = 0 if @load_delay_commit_reg == rt
            @load_delay_reg = rt
            @load_delay_value = val
            @step_cycles += 2
          end
        when 0x2B  # SW
          rs = (instruction >> 21) & 0x1F
          rt = (instruction >> 16) & 0x1F
          imm = instruction & 0xFFFF
          imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
          addr = (@regs[rs] + imm) & 0xFFFF_FFFF
          if (addr & 3) != 0
            exception(COP0::EXC_ADES, bad_addr: addr)
          elsif @memory.cache_isolated
            @memory.write32(addr, @regs[rt])
          else
            ph = addr & @region_mask[(addr >> 29) & 0x7]
            if ph < 0x0080_0000
              # PSX RAM chip is 2 MB but the address decoder uses an 8 MB
              # window; bits 0..20 are the only ones routed to the chip,
              # so every store within the 8 MB region commits to the same
              # 2 MB cell (symmetric mirror, matches real hardware).
              @ram_words[(ph & 0x001F_FFFF) >> 2] = @regs[rt] & 0xFFFF_FFFF
            else
              @memory.write32(addr, @regs[rt])
            end
          end
        when 0x05  # BNE
          rs = (instruction >> 21) & 0x1F
          rt = (instruction >> 16) & 0x1F
          if @regs[rs] != @regs[rt]
            imm = instruction & 0xFFFF
            imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
            @branch_target = (@pc + (imm << 2)) & 0xFFFF_FFFF
          end
        when 0x04  # BEQ
          rs = (instruction >> 21) & 0x1F
          rt = (instruction >> 16) & 0x1F
          if @regs[rs] == @regs[rt]
            imm = instruction & 0xFFFF
            imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
            @branch_target = (@pc + (imm << 2)) & 0xFFFF_FFFF
          end
        when 0x0F  # LUI
          rt = (instruction >> 16) & 0x1F
          cancel_load_delay_for(rt)
          @regs[rt] = ((instruction & 0xFFFF) << 16) & 0xFFFF_FFFF if rt != 0
        when 0x0D  # ORI
          rs = (instruction >> 21) & 0x1F
          rt = (instruction >> 16) & 0x1F
          cancel_load_delay_for(rt)
          @regs[rt] = (@regs[rs] | (instruction & 0xFFFF)) & 0xFFFF_FFFF if rt != 0
        when 0x00  # SPECIAL: nested decode for hot subops
          funct = instruction & 0x3F
          case funct
          when 0x00  # SLL
            rt = (instruction >> 16) & 0x1F
            rd = (instruction >> 11) & 0x1F
            shamt = (instruction >> 6) & 0x1F
            cancel_load_delay_for(rd)
            @regs[rd] = (@regs[rt] << shamt) & 0xFFFF_FFFF if rd != 0
          when 0x21  # ADDU
            rs = (instruction >> 21) & 0x1F
            rt = (instruction >> 16) & 0x1F
            rd = (instruction >> 11) & 0x1F
            cancel_load_delay_for(rd)
            @regs[rd] = (@regs[rs] + @regs[rt]) & 0xFFFF_FFFF if rd != 0
          when 0x23  # SUBU
            rs = (instruction >> 21) & 0x1F
            rt = (instruction >> 16) & 0x1F
            rd = (instruction >> 11) & 0x1F
            cancel_load_delay_for(rd)
            @regs[rd] = (@regs[rs] - @regs[rt]) & 0xFFFF_FFFF if rd != 0
          when 0x2A  # SLT
            rs = (instruction >> 21) & 0x1F
            rt = (instruction >> 16) & 0x1F
            rd = (instruction >> 11) & 0x1F
            a = @regs[rs]; a -= 0x1_0000_0000 if (a & 0x8000_0000) != 0
            b = @regs[rt]; b -= 0x1_0000_0000 if (b & 0x8000_0000) != 0
            cancel_load_delay_for(rd)
            @regs[rd] = (a < b ? 1 : 0) if rd != 0
          else
            execute_special(instruction)
          end
        when 0x01 then execute_bcondz(instruction)
        when 0x02 then op_j(instruction)
        when 0x03 then op_jal(instruction)
        when 0x06 then op_blez(instruction)
        when 0x07 then op_bgtz(instruction)
        when 0x08 then op_addi(instruction)
        when 0x0A then op_slti(instruction)
        when 0x0B then op_sltiu(instruction)
        when 0x0C then op_andi(instruction)
        when 0x0E then op_xori(instruction)
        when 0x10 then execute_cop0(instruction)
        when 0x11 then execute_cop1(instruction)
        when 0x12 then execute_cop2(instruction)
        when 0x13 then execute_cop3(instruction)
        when 0x20 then op_lb(instruction)
        when 0x21 then op_lh(instruction)
        when 0x22 then op_lwl(instruction)
        when 0x24 then op_lbu(instruction)
        when 0x25 then op_lhu(instruction)
        when 0x26 then op_lwr(instruction)
        when 0x28 then op_sb(instruction)
        when 0x29 then op_sh(instruction)
        when 0x2A then op_swl(instruction)
        when 0x2E then op_swr(instruction)
        when 0x30 then op_lwcN(instruction, 0)
        when 0x31 then op_lwcN(instruction, 1)
        when 0x32 then op_lwcN(instruction, 2)
        when 0x33 then op_lwcN(instruction, 3)
        when 0x38 then op_swcN(instruction, 0)
        when 0x39 then op_swcN(instruction, 1)
        when 0x3A then op_swcN(instruction, 2)
        when 0x3B then op_swcN(instruction, 3)
        else
          exception(COP0::EXC_RI)
        end
      end

      load_reg = @load_delay_commit_reg
      if load_reg != 0
        @regs[load_reg] = @load_delay_commit_value
        @load_delay_commit_reg = 0
      end

      # Handle branch delay (check @branch_target as instruction may have set
      # new one). @next_in_delay_slot must be set unconditionally so the next
      # step's exception path sees the right BD bit; we read @branch_target
      # once and stash the result in a local to do that with a single write.
      new_branch = @branch_target
      if new_branch
        @next_pc = new_branch
        @branch_target = nil
        @next_in_delay_slot = true
      else
        @next_in_delay_slot = false
      end
      @step_cycles
    end

    def disassemble_current
      instruction = @memory.read32(@pc)
      Disasm.disassemble(@pc, instruction)
    end

    def dump_registers
      lines = ["Registers:"]
      (0...32).each_slice(4) do |slice|
        row = slice.map { |i| format("R%-2d=%08X", i, @regs[i]) }.join("  ")
        lines << row
      end
      lines << format("PC=%08X  HI=%08X  LO=%08X", @pc, @hi, @lo)
      lines << format("SR=%08X  CAUSE=%08X  EPC=%08X", @cop0.sr, @cop0.cause, @cop0.epc)
      lines.join("\n")
    end

    # Called from run_fast at the same ~64-cycle batch boundary as the
    # device ticks. Previously this was done inside step() with its own
    # counter; lifting it out drops one ivar inc + branch per step. When
    # an IRQ actually fires we have to refresh @current_pc to point at the
    # *about-to-execute* instruction so exception() records the right EPC;
    # @next_in_delay_slot is already current (step's epilogue keeps it so).
    def check_interrupts
      return unless @interrupts
      @cop0.set_hardware_irq(@interrupts.pending?)
      if @cop0.interrupt_pending?
        # The real BIOS uses cache tricks while setting up the low-RAM
        # exception vectors. Until the emulator has an instruction-cache
        # model, vectoring through an all-zero 0x80000080 just executes a
        # long NOP sled and strands retail games during IRQ-heavy loaders.
        if exception_vector_unusable?
          service_installed_interrupt_callbacks
          return
        end

        @current_pc = @pc
        exception(COP0::EXC_INT)
      end
    end

    private

    def exception_vector_unusable?
      first = @memory.read32(0x8000_0080)
      return true if first.zero?

      opcode = (first >> 26) & 0x3F
      return false if opcode == 0x02 || opcode == 0x03 # j / jal

      rt = (first >> 16) & 0x1F
      return false if opcode == 0x0F && rt == 26 && @memory.read32(0x8000_0088) == 0x0340_0008

      true
    end

    def service_installed_interrupt_callbacks
      return false unless @memory.read32(CALLBACK_TABLE_FLAG) == 1

      pending = @memory.read16(0x1F80_1070) & @memory.read16(0x1F80_1074)
      pending &= @memory.read32(CALLBACK_TABLE_MASK)
      return false if pending.zero?

      11.times do |irq|
        bit = 1 << irq
        next if (pending & bit).zero?

        if bit == Interrupts::IRQ_DMA
          service_dma_channel_callbacks
          next
        end

        callback = @memory.read32(CALLBACK_TABLE_BASE + irq * 4)
        execute_interrupt_callback(callback) if callback != 0
      end

      @interrupts.write_stat((~pending) & 0x7FF)
      if @memory.dma && (@memory.dma.dicr & 0x8000_0000) != 0
        @interrupts.request(Interrupts::IRQ_DMA)
      end
      @cop0.set_hardware_irq(@interrupts.pending?)
      true
    end

    def service_dma_channel_callbacks
      dma = @memory.dma
      return unless dma

      dicr_flags = dma.dicr & 0x7F00_0000
      return if dicr_flags.zero?

      7.times do |channel|
        flag = 1 << (24 + channel)
        next if (dicr_flags & flag).zero?

        dma.write(0x74, (dma.dicr & 0x00FF_803F) | flag)
        callback = @memory.read32(DMA_CALLBACK_TABLE_BASE + channel * 4)
        execute_interrupt_callback(callback) if callback != 0
      end
    end

    def skip_rage_incomplete_cdrom_dma_callback?(pc)
      return false unless pc == RAGE_CDROM_DMA_CALLBACK

      cdrom = @memory.cdrom
      return false unless cdrom &&
                          cdrom.instance_variable_get(:@whole_sector) &&
                          cdrom.instance_variable_get(:@reading) &&
                          cdrom.instance_variable_get(:@seek_lba) == 304

      !rage_stream_dma_group_complete?
    end

    def rage_stream_dma_group_complete?
      queue = @memory.read32(RAGE_STREAM_QUEUE_BASE_PTR)
      index = @memory.read32(RAGE_STREAM_DMA_INDEX)
      return false if queue.zero?

      entry = queue + index * RAGE_STREAM_QUEUE_ENTRY_SIZE
      return false unless @memory.read16(entry) == 3

      sector_info = @memory.read32(entry + 4)
      sector_count = (sector_info >> 16) & 0xFFFF
      sector_index = sector_info & 0xFFFF
      return false unless sector_count.positive? && sector_index.zero?

      sector_count.times do |offset|
        sector_entry = entry + offset * RAGE_STREAM_QUEUE_ENTRY_SIZE
        return false unless @memory.read16(sector_entry) == 3

        info = @memory.read32(sector_entry + 4)
        return false unless ((info >> 16) & 0xFFFF) == sector_count
        return false unless (info & 0xFFFF) == offset
      end

      true
    end

    def execute_interrupt_callback(callback)
      saved_pc = @pc
      saved_next_pc = @next_pc
      saved_current_pc = @current_pc
      saved_branch_target = @branch_target
      saved_next_in_delay_slot = @next_in_delay_slot
      saved_load_delay_reg = @load_delay_reg
      saved_load_delay_value = @load_delay_value
      saved_load_delay_commit_reg = @load_delay_commit_reg
      saved_load_delay_commit_value = @load_delay_commit_value
      saved_hi = @hi
      saved_lo = @lo
      saved_regs = @regs.dup
      saved_cop0_regs = @cop0.regs.dup
      saved_cache_isolated = @memory.cache_isolated

      self.pc = callback
      @regs[31] = CALLBACK_RETURN_SENTINEL

      steps = 0
      step while @pc != CALLBACK_RETURN_SENTINEL && (steps += 1) < 20_000
    ensure
      @pc = saved_pc
      @next_pc = saved_next_pc
      @current_pc = saved_current_pc
      @branch_target = saved_branch_target
      @next_in_delay_slot = saved_next_in_delay_slot
      @load_delay_reg = saved_load_delay_reg
      @load_delay_value = saved_load_delay_value
      @load_delay_commit_reg = saved_load_delay_commit_reg
      @load_delay_commit_value = saved_load_delay_commit_value
      @hi = saved_hi
      @lo = saved_lo
      @regs = saved_regs
      @cop0.regs.replace(saved_cop0_regs)
      @memory.cache_isolated = saved_cache_isolated
    end

    # Intercept BIOS jump-table calls for PS-EXE testing. Returns true when
    # a known function (currently putchar/puts on A and B tables) was handled
    # and PC has been advanced to the caller via $ra.
    def intercept_bios_call(pc)
      phys = pc & 0x1FFFFFFF
      return false unless phys == BIOS_A_DISPATCH || phys == BIOS_B_DISPATCH

      code = @regs[9] & 0xFF  # $t1
      handled = case [phys, code]
                when [BIOS_A_DISPATCH, 0x3C], [BIOS_A_DISPATCH, 0x3D],
                     [BIOS_B_DISPATCH, 0x3B], [BIOS_B_DISPATCH, 0x3D]
                  return false unless @tty_handler
                  @tty_handler.call(:char, @regs[4] & 0xFF)
                  true
                when [BIOS_A_DISPATCH, 0x3E], [BIOS_B_DISPATCH, 0x3E]
                  return false unless @tty_handler
                  # puts(): raw string + newline.
                  @tty_handler.call(:str, "#{read_cstring(@regs[4])}\n")
                  true
                when [BIOS_A_DISPATCH, 0x3F], [BIOS_B_DISPATCH, 0x3F]
                  return false unless @tty_handler
                  # printf(fmt, ...): expand %s/%d/%u/%x/%X/%c/%% with
                  # a1..a3 then stack-passed varargs. ps1-tests rely on
                  # this for human-readable PASS/FAIL markers.
                  @tty_handler.call(:str, format_bios_printf(@regs[4]))
                  true
                else
                  false
                end
      return false unless handled

      # Return to caller: PC = $ra, no branch delay slot.
      ra = @regs[31]
      @pc = ra & 0xFFFF_FFFF
      @next_pc = (@pc + 4) & 0xFFFF_FFFF
      @branch_target = nil
      true
    end

    # Read a null-terminated string from memory at addr, capped to avoid
    # runaway reads on bad pointers.
    def read_cstring(addr, max: 4096)
      out = String.new
      max.times do
        b = @memory.read8((addr + out.length) & 0xFFFF_FFFF)
        break if b == 0
        out << b.chr
      end
      out
    end

    # Substitute %-specifiers in a BIOS-printf format string. Args 0..2
    # come from $a1..$a3; remaining args read from the caller's stack
    # at sp+16, sp+20, ... (MIPS o32 ABI layout). Supports %d/%i/%u/%x/
    # /%X/%c/%s and the field-width / zero-pad / # alternates we see in
    # ps1-tests log strings (e.g. "%08X", "%2u").
    def format_bios_printf(fmt_addr)
      fmt = read_cstring(fmt_addr)
      out = String.new(capacity: fmt.bytesize + 32)
      i = 0
      arg_idx = 0
      stack_base = @regs[29]  # $sp at call site

      next_arg = lambda do
        word = if arg_idx < 3
                 @regs[5 + arg_idx]   # $a1=5, $a2=6, $a3=7
               else
                 # MIPS o32: caller reserves a1..a3 spill space at sp+0..12,
                 # so args 4+ live at sp+16, sp+20, ...
                 @memory.read32((stack_base + 16 + (arg_idx - 3) * 4) & 0xFFFF_FFFF)
               end
        arg_idx += 1
        word & 0xFFFF_FFFF
      end

      while i < fmt.bytesize
        c = fmt.getbyte(i)
        if c != 0x25  # '%'
          out << c.chr
          i += 1
          next
        end

        # Parse "%[#0-9]*[diuxXcs%]"
        i += 1
        flags = String.new
        while i < fmt.bytesize && "#-+ ".include?(fmt[i])
          flags << fmt[i]
          i += 1
        end
        width = String.new
        while i < fmt.bytesize && (fmt[i] >= "0" && fmt[i] <= "9")
          width << fmt[i]
          i += 1
        end
        spec = i < fmt.bytesize ? fmt[i] : ""
        i += 1

        rb_fmt = "%#{flags}#{width}"
        case spec
        when "d", "i"
          v = next_arg.call
          v -= 0x1_0000_0000 if v >= 0x8000_0000
          out << format("#{rb_fmt}d", v)
        when "u"
          out << format("#{rb_fmt}d", next_arg.call)
        when "x"
          out << format("#{rb_fmt}x", next_arg.call)
        when "X"
          out << format("#{rb_fmt}X", next_arg.call)
        when "c"
          out << (next_arg.call & 0xFF).chr
        when "s"
          out << read_cstring(next_arg.call)
        when "%"
          out << "%"
        when ""
          # trailing '%' with nothing after; emit as-is
          out << "%"
        else
          # Unknown specifier — emit raw so we don't lose information.
          out << "%" << flags << width << spec
        end
      end
      out
    end

    def apply_load_delay
      if @load_delay_reg != 0
        @regs[@load_delay_reg] = @load_delay_value
        @load_delay_reg = 0
      end
    end

    def cancel_load_delay_for(reg)
      @load_delay_reg = 0 if @load_delay_reg == reg
      @load_delay_commit_reg = 0 if @load_delay_commit_reg == reg
    end

    def set_reg(reg, value)
      # If we're setting a register that has a pending load, cancel the load
      cancel_load_delay_for(reg)
      @regs[reg] = value & 0xFFFF_FFFF if reg != 0
    end

    def set_reg_delayed(reg, value)
      # Delayed loads - value appears after next instruction
      @load_delay_commit_reg = 0 if @load_delay_commit_reg == reg
      @load_delay_reg = reg
      @load_delay_value = value & 0xFFFF_FFFF
    end

    def branch(offset)
      # offset is already sign-extended 16-bit << 2
      @branch_target = (@pc + offset) & 0xFFFF_FFFF  # PC already advanced by 4
    end

    def jump(target)
      @branch_target = target & 0xFFFF_FFFF
    end

    def sign_extend8(value)
      (value & 0x80) != 0 ? (value | 0xFFFF_FF00) : value
    end

    def sign_extend16(value)
      (value & 0x8000) != 0 ? (value | 0xFFFF_0000) : value
    end

    def sign_extend32(value)
      # Convert to signed 32-bit for Ruby
      (value & 0x8000_0000) != 0 ? (value - 0x1_0000_0000) : value
    end

    def execute(instruction)
      # NOP check done in step() for performance
      opcode = (instruction >> 26) & 0x3F

      case opcode
      when 0x00 then execute_special(instruction)
      when 0x01 then execute_bcondz(instruction)
      when 0x02 then op_j(instruction)
      when 0x03 then op_jal(instruction)
      when 0x04 then op_beq(instruction)
      when 0x05 then op_bne(instruction)
      when 0x06 then op_blez(instruction)
      when 0x07 then op_bgtz(instruction)
      when 0x08 then op_addi(instruction)
      when 0x09 then op_addiu(instruction)
      when 0x0A then op_slti(instruction)
      when 0x0B then op_sltiu(instruction)
      when 0x0C then op_andi(instruction)
      when 0x0D then op_ori(instruction)
      when 0x0E then op_xori(instruction)
      when 0x0F then op_lui(instruction)
      when 0x10 then execute_cop0(instruction)
      when 0x11 then execute_cop1(instruction)
      when 0x12 then execute_cop2(instruction)  # GTE
      when 0x13 then execute_cop3(instruction)
      when 0x20 then op_lb(instruction)
      when 0x21 then op_lh(instruction)
      when 0x22 then op_lwl(instruction)
      when 0x23 then op_lw(instruction)
      when 0x24 then op_lbu(instruction)
      when 0x25 then op_lhu(instruction)
      when 0x26 then op_lwr(instruction)
      when 0x28 then op_sb(instruction)
      when 0x29 then op_sh(instruction)
      when 0x2A then op_swl(instruction)
      when 0x2B then op_sw(instruction)
      when 0x2E then op_swr(instruction)
      when 0x30 then op_lwcN(instruction, 0)
      when 0x31 then op_lwcN(instruction, 1)
      when 0x32 then op_lwcN(instruction, 2)
      when 0x33 then op_lwcN(instruction, 3)
      when 0x38 then op_swcN(instruction, 0)
      when 0x39 then op_swcN(instruction, 1)
      when 0x3A then op_swcN(instruction, 2)
      when 0x3B then op_swcN(instruction, 3)
      else
        exception(COP0::EXC_RI)
      end
    end

    def execute_special(instruction)
      funct = instruction & 0x3F

      case funct
      when 0x00 then op_sll(instruction)
      when 0x02 then op_srl(instruction)
      when 0x03 then op_sra(instruction)
      when 0x04 then op_sllv(instruction)
      when 0x06 then op_srlv(instruction)
      when 0x07 then op_srav(instruction)
      when 0x08 then op_jr(instruction)
      when 0x09 then op_jalr(instruction)
      when 0x0C then op_syscall(instruction)
      when 0x0D then op_break(instruction)
      when 0x10 then op_mfhi(instruction)
      when 0x11 then op_mthi(instruction)
      when 0x12 then op_mflo(instruction)
      when 0x13 then op_mtlo(instruction)
      when 0x18 then op_mult(instruction)
      when 0x19 then op_multu(instruction)
      when 0x1A then op_div(instruction)
      when 0x1B then op_divu(instruction)
      when 0x20 then op_add(instruction)
      when 0x21 then op_addu(instruction)
      when 0x22 then op_sub(instruction)
      when 0x23 then op_subu(instruction)
      when 0x24 then op_and(instruction)
      when 0x25 then op_or(instruction)
      when 0x26 then op_xor(instruction)
      when 0x27 then op_nor(instruction)
      when 0x2A then op_slt(instruction)
      when 0x2B then op_sltu(instruction)
      else
        exception(COP0::EXC_RI)
      end
    end

    def execute_bcondz(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = sign_extend16(instruction & 0xFFFF)
      offset = imm << 2

      val = sign_extend32(@regs[rs])
      link = (rt & 0x10) != 0
      bgez = (rt & 0x01) != 0

      test = bgez ? (val >= 0) : (val < 0)

      # Link stores return address in R31
      set_reg(31, @next_pc) if link

      branch(offset) if test
    end

    def execute_cop0(instruction)
      # COP0 is always available in kernel mode, and gated by SR.CU0 in user
      # mode (KUc=1). When user-mode software touches a disabled COP0 the
      # CPU raises Coprocessor-Unusable with CE=0.
      if (@cop0.sr & COP0::SR_KUC) != 0 && (@cop0.sr & COP0::SR_CU0) == 0
        exception(COP0::EXC_CPU, coprocessor: 0)
        return
      end

      cop_op = (instruction >> 21) & 0x1F

      case cop_op
      when 0x00 then op_mfc0(instruction)
      when 0x04 then op_mtc0(instruction)
      when 0x10 then op_rfe(instruction)
      else
        # Unknown COP0 ops silently no-op on the PSX (verified by
        # ps1-tests/cpu/cop testCop0InvalidOpcode -- "????" in source).
      end
    end

    # COP1 doesn't exist on the PSX. Access raises Coprocessor-Unusable when
    # CU1=0; with CU1=1 the instruction silently no-ops.
    def execute_cop1(_instruction)
      if (@cop0.sr & COP0::SR_CU1) == 0
        exception(COP0::EXC_CPU, coprocessor: 1)
      end
    end

    # COP3 doesn't exist either. Same model as COP1.
    def execute_cop3(_instruction)
      if (@cop0.sr & COP0::SR_CU3) == 0
        exception(COP0::EXC_CPU, coprocessor: 3)
      end
    end

    def execute_cop2(instruction)
      if (@cop0.sr & COP0::SR_CU2) == 0
        exception(COP0::EXC_CPU, coprocessor: 2)
        return
      end

      if (instruction & (1 << 25)) != 0
        @gte.execute(instruction)
        @step_cycles += @gte.op_cycles - 1  # base ALU cycle already counted
        return
      end

      cop_op = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F

      case cop_op
      when 0x00 then set_reg_delayed(rt, @gte.read_data(rd))     # MFC2
      when 0x02 then set_reg_delayed(rt, @gte.read_control(rd))  # CFC2
      when 0x04 then @gte.write_data(rd, @regs[rt])              # MTC2
      when 0x06 then @gte.write_control(rd, @regs[rt])           # CTC2
        # Unknown COP2 register ops silently no-op (testCop2InvalidOpcode).
      end
    end

    # R-type ALU operations (decode inlined for performance)
    def op_sll(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      shamt = (instruction >> 6) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rt] << shamt) & 0xFFFF_FFFF if rd != 0
    end

    def op_srl(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      shamt = (instruction >> 6) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rt] >> shamt) & 0xFFFF_FFFF if rd != 0
    end

    def op_sra(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      shamt = (instruction >> 6) & 0x1F
      val = sign_extend32(@regs[rt])
      set_reg(rd, val >> shamt)
    end

    def op_sllv(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rt] << (@regs[rs] & 0x1F))
    end

    def op_srlv(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rt] >> (@regs[rs] & 0x1F))
    end

    def op_srav(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      val = sign_extend32(@regs[rt])
      set_reg(rd, val >> (@regs[rs] & 0x1F))
    end

    def op_jr(instruction)
      rs = (instruction >> 21) & 0x1F
      jump(@regs[rs])
    end

    def op_jalr(instruction)
      rs = (instruction >> 21) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @next_pc)
      jump(@regs[rs])
    end

    def op_syscall(_instruction)
      exception(COP0::EXC_SYS)
    end

    def op_break(_instruction)
      exception(COP0::EXC_BP)
    end

    def op_mfhi(instruction)
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @hi)
    end

    def op_mthi(instruction)
      rs = (instruction >> 21) & 0x1F
      @hi = @regs[rs]
    end

    def op_mflo(instruction)
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @lo)
    end

    def op_mtlo(instruction)
      rs = (instruction >> 21) & 0x1F
      @lo = @regs[rs]
    end

    def op_mult(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      a = sign_extend32(@regs[rs])
      b = sign_extend32(@regs[rt])
      result = a * b
      @lo = result & 0xFFFF_FFFF
      @hi = (result >> 32) & 0xFFFF_FFFF
    end

    def op_multu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      result = @regs[rs] * @regs[rt]
      @lo = result & 0xFFFF_FFFF
      @hi = (result >> 32) & 0xFFFF_FFFF
    end

    def op_div(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      num = sign_extend32(@regs[rs])
      den = sign_extend32(@regs[rt])

      if den == 0
        # Division by zero
        @lo = num >= 0 ? 0xFFFF_FFFF : 1
        @hi = @regs[rs]
      elsif num == -0x8000_0000 && den == -1
        # Overflow
        @lo = 0x8000_0000
        @hi = 0
      else
        @lo = (num / den) & 0xFFFF_FFFF
        @hi = (num % den) & 0xFFFF_FFFF
      end
    end

    def op_divu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      num = @regs[rs]
      den = @regs[rt]

      if den == 0
        @lo = 0xFFFF_FFFF
        @hi = num
      else
        @lo = num / den
        @hi = num % den
      end
    end

    def op_add(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      a = sign_extend32(@regs[rs])
      b = sign_extend32(@regs[rt])
      sum = a + b
      # Signed overflow: result doesn't fit in 32 bits signed.
      if sum > 0x7FFF_FFFF || sum < -0x8000_0000
        exception(COP0::EXC_OV)
        return
      end
      set_reg(rd, sum)
    end

    def op_addu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rs] + @regs[rt]) & 0xFFFF_FFFF if rd != 0
    end

    def op_sub(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      a = sign_extend32(@regs[rs])
      b = sign_extend32(@regs[rt])
      diff = a - b
      if diff > 0x7FFF_FFFF || diff < -0x8000_0000
        exception(COP0::EXC_OV)
        return
      end
      set_reg(rd, diff)
    end

    def op_subu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rs] - @regs[rt]) & 0xFFFF_FFFF if rd != 0
    end

    def op_and(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rs] & @regs[rt]) & 0xFFFF_FFFF if rd != 0
    end

    def op_or(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rs] | @regs[rt]) & 0xFFFF_FFFF if rd != 0
    end

    def op_xor(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rs] ^ @regs[rt]) & 0xFFFF_FFFF if rd != 0
    end

    def op_nor(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (~(@regs[rs] | @regs[rt])) & 0xFFFF_FFFF if rd != 0
    end

    def op_slt(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      a = @regs[rs]; a -= 0x1_0000_0000 if (a & 0x8000_0000) != 0
      b = @regs[rt]; b -= 0x1_0000_0000 if (b & 0x8000_0000) != 0
      cancel_load_delay_for(rd)
      @regs[rd] = (a < b ? 1 : 0) if rd != 0
    end

    def op_sltu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      cancel_load_delay_for(rd)
      @regs[rd] = (@regs[rs] < @regs[rt] ? 1 : 0) if rd != 0
    end

    # I-type operations (decode inlined for performance)
    def op_addi(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      a = sign_extend32(@regs[rs])
      # imm is a signed 16-bit value; treat the top bit as sign.
      b = (imm & 0x8000) != 0 ? imm - 0x10000 : imm
      sum = a + b
      if sum > 0x7FFF_FFFF || sum < -0x8000_0000
        exception(COP0::EXC_OV)
        return
      end
      set_reg(rt, sum)
    end

    def op_addiu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # Inline sign_extend16 and set_reg for hot path
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
      cancel_load_delay_for(rt)
      @regs[rt] = (@regs[rs] + imm) & 0xFFFF_FFFF if rt != 0
    end

    def op_slti(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      a = sign_extend32(@regs[rs])
      b = sign_extend16(imm)
      b = sign_extend32(b & 0xFFFF_FFFF)
      set_reg(rt, a < b ? 1 : 0)
    end

    def op_sltiu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] < (sign_extend16(imm) & 0xFFFF_FFFF) ? 1 : 0)
    end

    def op_andi(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] & imm)
    end

    def op_ori(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] | imm)
    end

    def op_xori(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] ^ imm)
    end

    def op_lui(instruction)
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      cancel_load_delay_for(rt)
      @regs[rt] = (imm << 16) & 0xFFFF_FFFF if rt != 0
    end

    # Branch operations (decode inlined)
    def op_beq(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      if @regs[rs] == @regs[rt]
        imm = instruction & 0xFFFF
        imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
        @branch_target = (@pc + (imm << 2)) & 0xFFFF_FFFF
      end
    end

    def op_bne(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      if @regs[rs] != @regs[rt]
        imm = instruction & 0xFFFF
        imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
        @branch_target = (@pc + (imm << 2)) & 0xFFFF_FFFF
      end
    end

    def op_blez(instruction)
      rs = (instruction >> 21) & 0x1F
      imm = instruction & 0xFFFF
      branch(sign_extend16(imm) << 2) if sign_extend32(@regs[rs]) <= 0
    end

    def op_bgtz(instruction)
      rs = (instruction >> 21) & 0x1F
      val = @regs[rs]
      # sign_extend32 check: value > 0 and not negative (high bit clear or value is 0)
      if val != 0 && (val & 0x8000_0000) == 0
        imm = instruction & 0xFFFF
        imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
        @branch_target = (@pc + (imm << 2)) & 0xFFFF_FFFF
      end
    end

    # Jump operations (decode inlined)
    def op_j(instruction)
      target = instruction & 0x03FF_FFFF
      jump((@pc & 0xF000_0000) | (target << 2))
    end

    def op_jal(instruction)
      target = instruction & 0x03FF_FFFF
      set_reg(31, @next_pc)
      jump((@pc & 0xF000_0000) | (target << 2))
    end

    # Load operations (decode inlined). Each load bumps @step_cycles by 1 to
    # approximate the load-delay slot + RAM access cost — without this a tight
    # poll loop runs faster than 1 VBlank period and BIOS VSync times out.
    def op_lb(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = @regs[rs] + sign_extend16(imm)
      val = sign_extend8(@memory.read8(addr))
      set_reg_delayed(rt, val)
      @step_cycles += 1
    end

    def op_lh(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      if (addr & 1) != 0
        exception(COP0::EXC_ADEL, bad_addr: addr)
        return
      end
      val = sign_extend16(@memory.read16(addr))
      set_reg_delayed(rt, val)
      @step_cycles += 1
    end

    def op_lw(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0  # sign-extend
      addr = (@regs[rs] + imm) & 0xFFFF_FFFF
      if (addr & 3) != 0
        exception(COP0::EXC_ADEL, bad_addr: addr)
        return
      end
      # Inline the RAM fast path; the bootmap profile shows ~27% of all
      # executed ops are LW, and the overwhelming majority hit main RAM.
      phys = addr & @region_mask[(addr >> 29) & 0x7]
      val = if phys < 0x0080_0000
              @ram_words[(phys & 0x001F_FFFF) >> 2]
            else
              @memory.read32(addr) & 0xFFFF_FFFF
            end
      @load_delay_commit_reg = 0 if @load_delay_commit_reg == rt
      @load_delay_reg = rt
      @load_delay_value = val
      @step_cycles += 2
    end

    def op_lbu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # Inline sign_extend16
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
      addr = (@regs[rs] + imm) & 0xFFFF_FFFF
      # Inline set_reg_delayed
      @load_delay_commit_reg = 0 if @load_delay_commit_reg == rt
      @load_delay_reg = rt
      @load_delay_value = @memory.read8(addr)
      @step_cycles += 1
    end

    def op_lhu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      if (addr & 1) != 0
        exception(COP0::EXC_ADEL, bad_addr: addr)
        return
      end
      set_reg_delayed(rt, @memory.read16(addr))
      @step_cycles += 1
    end

    def op_lwl(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)

      # LWL/LWR pairs merge through a pending load-delay value when the
      # previous instruction loaded the same target register.
      current = (@load_delay_commit_reg == rt) ? @load_delay_commit_value : @regs[rt]
      case addr & 3
      when 0 then result = (current & 0x00FF_FFFF) | (val << 24)
      when 1 then result = (current & 0x0000_FFFF) | (val << 16)
      when 2 then result = (current & 0x0000_00FF) | (val << 8)
      when 3 then result = val
      end
      set_reg_delayed(rt, result)
    end

    def op_lwr(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)

      current = (@load_delay_commit_reg == rt) ? @load_delay_commit_value : @regs[rt]
      case addr & 3
      when 0 then result = val
      when 1 then result = (current & 0xFF00_0000) | (val >> 8)
      when 2 then result = (current & 0xFFFF_0000) | (val >> 16)
      when 3 then result = (current & 0xFFFF_FF00) | (val >> 24)
      end
      set_reg_delayed(rt, result)
    end

    # Store operations (decode inlined)
    def op_sb(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # Inline sign_extend16
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
      addr = (@regs[rs] + imm) & 0xFFFF_FFFF
      @memory.write8(addr, @regs[rt])
    end

    def op_sh(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      if (addr & 1) != 0
        exception(COP0::EXC_ADES, bad_addr: addr)
        return
      end
      @memory.write16(addr, @regs[rt])
    end

    def op_sw(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0  # sign-extend
      addr = (@regs[rs] + imm) & 0xFFFF_FFFF
      if (addr & 3) != 0
        exception(COP0::EXC_ADES, bad_addr: addr)
        return
      end
      # Inline the RAM fast path. cache_isolated is true only briefly
      # during BIOS cache flushes, so the slow path through Memory#write32
      # is fine for that case.
      if @memory.cache_isolated
        @memory.write32(addr, @regs[rt])
        return
      end
      phys = addr & @region_mask[(addr >> 29) & 0x7]
      if phys < 0x0080_0000
        @ram_words[(phys & 0x001F_FFFF) >> 2] = @regs[rt] & 0xFFFF_FFFF
      else
        @memory.write32(addr, @regs[rt])
      end
    end

    def op_swl(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)
      reg = @regs[rt]

      case addr & 3
      when 0 then result = (val & 0xFFFF_FF00) | (reg >> 24)
      when 1 then result = (val & 0xFFFF_0000) | (reg >> 16)
      when 2 then result = (val & 0xFF00_0000) | (reg >> 8)
      when 3 then result = reg
      end
      @memory.write32(aligned, result)
    end

    def op_swr(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)
      reg = @regs[rt]

      case addr & 3
      when 0 then result = reg
      when 1 then result = (val & 0x0000_00FF) | (reg << 8)
      when 2 then result = (val & 0x0000_FFFF) | (reg << 16)
      when 3 then result = (val & 0x00FF_FFFF) | (reg << 24)
      end
      @memory.write32(aligned, result)
    end

    # Coprocessor load (LWCn). For COP2 we move the word into the GTE data
    # register; for the other coprocessors we either no-op (when enabled) or
    # raise Coprocessor-Unusable (when disabled). Note that COP0/1/3 don't
    # actually have memory data registers on the PSX -- BIOS catches the
    # exception or treats the instruction as harmless.
    def op_lwcN(instruction, cop)
      unless coprocessor_usable?(cop)
        exception(COP0::EXC_CPU, coprocessor: cop)
        return
      end
      if cop == 2
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = instruction & 0xFFFF
        addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
        @gte.write_data(rt, @memory.read32(addr))
      end
    end

    def op_swcN(instruction, cop)
      unless coprocessor_usable?(cop)
        exception(COP0::EXC_CPU, coprocessor: cop)
        return
      end
      if cop == 2
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = instruction & 0xFFFF
        addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
        @memory.write32(addr, @gte.read_data(rt))
      end
    end

    # Whether LWCn / SWCn for the given coprocessor is allowed. Unlike the
    # main COP0 register move instructions (MFC0/MTC0/RFE) the load/store
    # variants require CU0 to be set explicitly even in kernel mode -- this
    # is what ps1-tests/cpu/cop testSwc0Disabled exercises.
    def coprocessor_usable?(cop)
      mask = case cop
             when 0 then COP0::SR_CU0
             when 1 then COP0::SR_CU1
             when 2 then COP0::SR_CU2
             when 3 then COP0::SR_CU3
             end
      (@cop0.sr & mask) != 0
    end

    # COP0 operations
    def op_mfc0(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg_delayed(rt, @cop0.read(rd))
    end

    def op_mtc0(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      val = @regs[rt]

      @cop0.write(rd, val)

      # Update memory cache isolation state
      @memory.cache_isolated = @cop0.cache_isolated? if rd == COP0::SR
    end

    def op_rfe(_instruction)
      @cop0.return_from_exception
    end

    def exception(cause, bad_addr: nil, coprocessor: nil)
      vector = @cop0.enter_exception(
        cause,
        @current_pc,
        in_delay_slot: @next_in_delay_slot,
        bad_addr: bad_addr,
        coprocessor: coprocessor
      )

      @pc = vector
      @next_pc = @pc + 4
      @branch_target = nil
      @next_in_delay_slot = false
    end
  end
end
