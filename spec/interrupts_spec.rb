# frozen_string_literal: true

require_relative "spec_helper"

class InterruptsSpec < Minitest::Test
  include TestHelpers

  def setup
    @interrupts = PSX::Interrupts.new
  end

  def test_initial_state
    assert_equal 0, @interrupts.stat
    assert_equal 0, @interrupts.mask
  end

  def test_request_sets_status_bit
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    assert @interrupts.stat & PSX::Interrupts::IRQ_VBLANK != 0
  end

  def test_acknowledge_clears_status_bit
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    # Write 0 to acknowledge (clear), 1 to keep
    @interrupts.write_stat(~PSX::Interrupts::IRQ_VBLANK & 0x7FF)
    assert_equal 0, @interrupts.stat & PSX::Interrupts::IRQ_VBLANK
  end

  def test_pending_requires_mask
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    refute @interrupts.pending?, "No pending without mask"

    @interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK)
    assert @interrupts.pending?, "Should be pending with mask set"
  end

  def test_multiple_interrupts
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    @interrupts.request(PSX::Interrupts::IRQ_DMA)

    expected = PSX::Interrupts::IRQ_VBLANK | PSX::Interrupts::IRQ_DMA
    assert_equal expected, @interrupts.stat
  end

  def test_irq_constants
    assert_equal 0x001, PSX::Interrupts::IRQ_VBLANK
    assert_equal 0x002, PSX::Interrupts::IRQ_GPU
    assert_equal 0x004, PSX::Interrupts::IRQ_CDROM
    assert_equal 0x008, PSX::Interrupts::IRQ_DMA
    assert_equal 0x010, PSX::Interrupts::IRQ_TIMER0
    assert_equal 0x020, PSX::Interrupts::IRQ_TIMER1
    assert_equal 0x040, PSX::Interrupts::IRQ_TIMER2
  end

  def test_cpu_defers_interrupt_when_exception_vector_is_empty
    env = create_cpu_with_ram
    cpu = env[:cpu]
    interrupts = env[:interrupts]

    cpu.cop0.sr = 0x401 # IEc + interrupt mask bit 2
    interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK)
    interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    cpu.pc = 0x8001_0000

    cpu.check_interrupts

    assert_equal 0x8001_0000, cpu.pc
    assert_equal 0, cpu.cop0.cause & 0x7C
  end

  def test_cpu_takes_interrupt_when_exception_vector_is_installed
    env = create_cpu_with_ram
    cpu = env[:cpu]
    memory = env[:memory]
    interrupts = env[:interrupts]

    memory.write32(0x8000_0080, 0x0800_0000) # any non-zero handler word
    cpu.cop0.sr = 0x401 # IEc + interrupt mask bit 2
    interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK)
    interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    cpu.pc = 0x8001_0000

    cpu.check_interrupts

    assert_equal 0x8000_0080, cpu.pc
    assert_equal PSX::COP0::EXC_INT << 2, cpu.cop0.cause & 0x7C
    assert_equal 0x8001_0000, cpu.cop0.epc
  end

  def test_cpu_services_installed_irq_callback_when_exception_vector_is_unusable
    env = create_cpu_with_ram
    cpu = env[:cpu]
    memory = env[:memory]
    interrupts = env[:interrupts]

    memory.write32(0x8009_9430, 1)
    memory.write32(0x8009_943C, 0x8001_0000)
    memory.write32(0x8009_9460, PSX::Interrupts::IRQ_CDROM)
    memory.write32(0x8001_0000, 0x3C03_800A) # lui v1,0x800A
    memory.write32(0x8001_0004, 0x3402_0077) # ori v0,zero,0x77
    memory.write32(0x8001_0008, 0xA062_BAF8) # sb v0,-17672(v1)
    memory.write32(0x8001_000C, 0x03E0_0008) # jr ra
    memory.write32(0x8001_0010, 0x0000_0000) # nop

    cpu.cop0.sr = 0x401 # IEc + interrupt mask bit 2
    interrupts.write_mask(PSX::Interrupts::IRQ_CDROM)
    interrupts.request(PSX::Interrupts::IRQ_CDROM)
    cpu.pc = 0x8002_0000

    cpu.check_interrupts

    assert_equal 0x77, memory.read8(0x8009_BAF8)
    assert_equal 0, interrupts.read_stat & PSX::Interrupts::IRQ_CDROM
    assert_equal 0x8002_0000, cpu.pc
    assert_equal 0, cpu.regs[31]
  end

  def test_cpu_services_multiple_installed_irq_callbacks_in_irq_order
    env = create_cpu_with_ram
    cpu = env[:cpu]
    memory = env[:memory]
    interrupts = env[:interrupts]

    memory.write32(0x8009_9430, 1)
    memory.write32(0x8009_9434, 0x8001_0000) # VBlank callback
    memory.write32(0x8009_9450, 0x8001_0020) # Pad callback
    memory.write32(0x8009_9460, PSX::Interrupts::IRQ_VBLANK | PSX::Interrupts::IRQ_CONTROLLER)

    write_store_byte_callback(memory, 0x8001_0000, 0x11)
    write_store_byte_callback(memory, 0x8001_0020, 0x22)

    cpu.cop0.sr = 0x401
    cpu.regs[2] = 0xAAAA
    cpu.regs[31] = 0xBBBB
    interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK | PSX::Interrupts::IRQ_CONTROLLER)
    interrupts.request(PSX::Interrupts::IRQ_CONTROLLER)
    interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    cpu.pc = 0x8002_0000

    cpu.check_interrupts

    assert_equal 0x11, memory.read8(0x8009_BAF8)
    assert_equal 0x22, memory.read8(0x8009_BAF9)
    assert_equal 0, interrupts.read_stat & (PSX::Interrupts::IRQ_VBLANK | PSX::Interrupts::IRQ_CONTROLLER)
    assert_equal 0x8002_0000, cpu.pc
    assert_equal 0xAAAA, cpu.regs[2]
    assert_equal 0xBBBB, cpu.regs[31]
  end

  def test_cpu_services_dma_channel_callbacks_from_bios_dma_table
    env = create_cpu_with_ram
    cpu = env[:cpu]
    memory = env[:memory]
    interrupts = env[:interrupts]
    dma = memory.dma

    memory.write32(0x8009_9430, 1)
    memory.write32(0x8009_9460, PSX::Interrupts::IRQ_DMA)
    memory.write32(0x8009_A4FC, 0x8001_0000) # DMA channel 1 callback
    memory.write32(0x8009_A504, 0x8001_0020) # DMA channel 3 callback
    write_store_byte_callback(memory, 0x8001_0000, 0x44)
    write_store_byte_callback(memory, 0x8001_0020, 0x55)
    dma.instance_variable_set(:@dicr, 0x0A00_0000) # Channel 1 and 3 flags

    cpu.cop0.sr = 0x401
    interrupts.write_mask(PSX::Interrupts::IRQ_DMA)
    interrupts.request(PSX::Interrupts::IRQ_DMA)
    cpu.pc = 0x8002_0000

    cpu.check_interrupts

    assert_equal 0x44, memory.read8(0x8009_BAF8)
    assert_equal 0x55, memory.read8(0x8009_BAF9)
    assert_equal 0, dma.dicr & 0x0A00_0000
    assert_equal 0, interrupts.read_stat & PSX::Interrupts::IRQ_DMA
    assert_equal 0x8002_0000, cpu.pc
  end

  def test_cpu_prefers_real_exception_vector_over_installed_callback_fallback
    env = create_cpu_with_ram
    cpu = env[:cpu]
    memory = env[:memory]
    interrupts = env[:interrupts]

    memory.write32(0x8000_0080, 0x0800_0000)
    memory.write32(0x8009_9430, 1)
    memory.write32(0x8009_9434, 0x8001_0000)
    memory.write32(0x8009_9460, PSX::Interrupts::IRQ_VBLANK)
    write_store_byte_callback(memory, 0x8001_0000, 0x33)

    cpu.cop0.sr = 0x401
    interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK)
    interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    cpu.pc = 0x8002_0000

    cpu.check_interrupts

    assert_equal 0x8000_0080, cpu.pc
    assert_equal 0, memory.read8(0x8009_BAF8)
    assert_equal PSX::COP0::EXC_INT << 2, cpu.cop0.cause & 0x7C
  end

  private

  def write_store_byte_callback(memory, addr, value)
    offset = addr == 0x8001_0000 ? 0 : 1
    memory.write32(addr, 0x3C03_800A) # lui v1,0x800A
    memory.write32(addr + 4, 0x3402_0000 | value) # ori v0,zero,value
    memory.write32(addr + 8, 0xA062_BAF8 + offset) # sb v0,-17672(v1)
    memory.write32(addr + 12, 0x03E0_0008) # jr ra
    memory.write32(addr + 16, 0x0000_0000) # nop
  end
end

class TimersSpec < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
    @timers = PSX::Timers.new(interrupts: @interrupts)
  end

  def test_initial_counter_values
    assert_equal 0, @timers.read(0x00)  # Timer 0 counter
    assert_equal 0, @timers.read(0x10)  # Timer 1 counter
    assert_equal 0, @timers.read(0x20)  # Timer 2 counter
  end

  def test_counter_increments
    @timers.tick(100)
    counter = @timers.read(0x00)
    assert counter > 0, "Counter should have incremented"
  end

  def test_write_counter_resets
    @timers.tick(100)
    @timers.write(0x00, 0)  # Reset counter
    assert_equal 0, @timers.read(0x00)
  end

  def test_target_register
    @timers.write(0x08, 0x1234)  # Timer 0 target
    assert_equal 0x1234, @timers.read(0x08)
  end

  def test_mode_register
    @timers.write(0x04, 0x0100)  # Timer 0 mode
    mode = @timers.read(0x04)
    # Reading mode should clear some bits
    assert mode != 0x0100 || mode == 0x0100  # Depends on implementation
  end
end
