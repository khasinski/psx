# frozen_string_literal: true

require_relative "spec_helper"

# Direct unit-level coverage for the BIOS printf intercept's format-string
# expansion. ps1-tests rely on %s/%u/%x/%X/%c/%d substitution working;
# without it the tally is just the raw format string with literal "%u".
class BiosPrintfTest < Minitest::Test
  include TestHelpers

  def setup
    env = create_cpu_with_ram
    @cpu = env[:cpu]
    @memory = env[:memory]
    @captured = String.new
    @cpu.tty_handler = ->(kind, val) do
      case kind
      when :char then @captured << val.chr
      when :str  then @captured << val
      end
    end
  end

  def test_printf_substitutes_d
    assert_equal "n=42\n", run_printf("n=%d\n", [42])
  end

  def test_printf_substitutes_u
    assert_equal "u=4294967295", run_printf("u=%u", [0xFFFF_FFFF])
  end

  def test_printf_substitutes_x_and_X_with_width
    assert_equal "0x000000ff 0xCAFEBABE",
                 run_printf("0x%08x 0x%08X", [0xFF, 0xCAFE_BABE])
  end

  def test_printf_substitutes_c
    assert_equal "A", run_printf("%c", ["A".ord])
  end

  def test_printf_substitutes_s
    str_addr = 0x100
    write_cstring(str_addr, "hello")
    assert_equal "hi: hello", run_printf("hi: %s", [str_addr])
  end

  def test_printf_signed_negative_d
    assert_equal "n=-1", run_printf("n=%d", [0xFFFF_FFFF])
  end

  def test_printf_double_percent
    assert_equal "100%", run_printf("100%%", [])
  end

  def test_printf_pulls_extra_args_from_stack
    sp = 0x801F_FF00
    @cpu.regs[29] = sp
    # MIPS o32 stack args start at sp+16. Stash the 4th, 5th args there.
    @memory.write32(sp + 16, 0x44)  # 4th arg (after a1/a2/a3)
    @memory.write32(sp + 20, 0x55)
    assert_equal "1 2 3 68 85", run_printf("%d %d %d %d %d", [1, 2, 3], leave_sp: true)
  end

  private

  def write_cstring(addr, str)
    str.each_byte.with_index { |b, i| @memory.write8(addr + i, b) }
    @memory.write8(addr + str.bytesize, 0)
  end

  def run_printf(fmt, args, leave_sp: false)
    fmt_addr = 0x200
    write_cstring(fmt_addr, fmt)
    @cpu.regs[4] = fmt_addr               # $a0 = format
    args.each_with_index do |a, i|
      @cpu.regs[5 + i] = a if i < 3        # $a1..$a3
    end
    @cpu.regs[29] = 0x801F_FF00 unless leave_sp
    @cpu.send(:format_bios_printf, fmt_addr)
  end
end
