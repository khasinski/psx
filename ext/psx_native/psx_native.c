/*
 * PSX Native CPU Extension
 *
 * High-performance CPU core for PSX emulator.
 * Implements MIPS R3000A instruction set.
 */

#include <ruby.h>
#include <stdint.h>
#include <stdbool.h>

// CPU State
typedef struct {
    uint32_t regs[32];      // General purpose registers
    uint32_t pc;            // Program counter
    uint32_t next_pc;       // Next PC (for branch delay)
    uint32_t hi, lo;        // Multiplication/division results
    uint32_t current_pc;    // PC of current instruction (for exceptions)

    // Load delay slot
    uint32_t load_delay_reg;
    uint32_t load_delay_value;

    // Branch delay slot
    bool in_delay_slot;
    uint32_t branch_target;
    bool branch_pending;

    // Interrupt handling
    uint32_t interrupt_check_counter;
    uint32_t interrupt_check_interval;

    // Ruby objects for callbacks
    VALUE memory;
    VALUE interrupts;
    VALUE cop0;
} CPUState;

static VALUE cNativeCPU;
static VALUE cExecutionError;

// Macros for instruction decoding
#define OPCODE(i)   (((i) >> 26) & 0x3F)
#define RS(i)       (((i) >> 21) & 0x1F)
#define RT(i)       (((i) >> 16) & 0x1F)
#define RD(i)       (((i) >> 11) & 0x1F)
#define SHAMT(i)    (((i) >> 6) & 0x1F)
#define FUNCT(i)    ((i) & 0x3F)
#define IMM16(i)    ((i) & 0xFFFF)
#define IMM26(i)    ((i) & 0x03FFFFFF)

// Sign extension
static inline uint32_t sign_extend16(uint32_t value) {
    return (value & 0x8000) ? (value | 0xFFFF0000) : value;
}

static inline int32_t sign_extend32(uint32_t value) {
    return (int32_t)value;
}

// Data type definition for Ruby wrapper
static const rb_data_type_t cpu_data_type = {
    .wrap_struct_name = "NativeCPU",
    .function = {
        .dmark = NULL,
        .dfree = RUBY_DEFAULT_FREE,
        .dsize = NULL,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

// Get CPU state from Ruby object
static CPUState* get_cpu(VALUE self) {
    CPUState *cpu;
    TypedData_Get_Struct(self, CPUState, &cpu_data_type, cpu);
    return cpu;
}

// Memory access via Ruby callbacks
static uint32_t mem_read32(CPUState *cpu, uint32_t addr) {
    VALUE result = rb_funcall(cpu->memory, rb_intern("read32"), 1, UINT2NUM(addr));
    return NUM2UINT(result);
}

static uint32_t mem_read16(CPUState *cpu, uint32_t addr) {
    VALUE result = rb_funcall(cpu->memory, rb_intern("read16"), 1, UINT2NUM(addr));
    return NUM2UINT(result);
}

static uint32_t mem_read8(CPUState *cpu, uint32_t addr) {
    VALUE result = rb_funcall(cpu->memory, rb_intern("read8"), 1, UINT2NUM(addr));
    return NUM2UINT(result);
}

static void mem_write32(CPUState *cpu, uint32_t addr, uint32_t value) {
    rb_funcall(cpu->memory, rb_intern("write32"), 2, UINT2NUM(addr), UINT2NUM(value));
}

static void mem_write16(CPUState *cpu, uint32_t addr, uint32_t value) {
    rb_funcall(cpu->memory, rb_intern("write16"), 2, UINT2NUM(addr), UINT2NUM(value));
}

static void mem_write8(CPUState *cpu, uint32_t addr, uint32_t value) {
    rb_funcall(cpu->memory, rb_intern("write8"), 2, UINT2NUM(addr), UINT2NUM(value));
}

// Register operations
static inline void set_reg(CPUState *cpu, uint32_t reg, uint32_t value) {
    if (cpu->load_delay_reg == reg) cpu->load_delay_reg = 0;
    if (reg != 0) cpu->regs[reg] = value;
}

static inline void set_reg_delayed(CPUState *cpu, uint32_t reg, uint32_t value) {
    cpu->load_delay_reg = reg;
    cpu->load_delay_value = value;
}

static inline void branch(CPUState *cpu, int32_t offset) {
    cpu->branch_target = cpu->pc + offset;
    cpu->branch_pending = true;
}

static inline void jump(CPUState *cpu, uint32_t target) {
    cpu->branch_target = target;
    cpu->branch_pending = true;
}

// Exception handling
static void raise_exception(CPUState *cpu, uint32_t cause) {
    rb_funcall(cpu->cop0, rb_intern("enter_exception"), 3,
               UINT2NUM(cpu->current_pc),
               UINT2NUM(cause),
               cpu->in_delay_slot ? Qtrue : Qfalse);
    cpu->pc = 0x80000080;
    cpu->next_pc = cpu->pc + 4;
    cpu->branch_pending = false;
}

// COP0 operations
static void execute_cop0(CPUState *cpu, uint32_t instruction) {
    uint32_t rs = RS(instruction);
    uint32_t rt = RT(instruction);
    uint32_t rd = RD(instruction);

    switch (rs) {
        case 0x00: // MFC0 - Move from COP0
            {
                VALUE val = rb_funcall(cpu->cop0, rb_intern("read"), 1, UINT2NUM(rd));
                set_reg_delayed(cpu, rt, NUM2UINT(val));
            }
            break;
        case 0x04: // MTC0 - Move to COP0
            rb_funcall(cpu->cop0, rb_intern("write"), 2, UINT2NUM(rd), UINT2NUM(cpu->regs[rt]));
            break;
        case 0x10: // RFE - Return from exception
            if ((instruction & 0x3F) == 0x10) {
                rb_funcall(cpu->cop0, rb_intern("return_from_exception"), 0);
            }
            break;
    }
}

// SPECIAL instructions (opcode 0x00)
static void execute_special(CPUState *cpu, uint32_t instruction) {
    uint32_t rs = RS(instruction);
    uint32_t rt = RT(instruction);
    uint32_t rd = RD(instruction);
    uint32_t shamt = SHAMT(instruction);
    uint32_t funct = FUNCT(instruction);

    switch (funct) {
        case 0x00: // SLL
            set_reg(cpu, rd, cpu->regs[rt] << shamt);
            break;
        case 0x02: // SRL
            set_reg(cpu, rd, cpu->regs[rt] >> shamt);
            break;
        case 0x03: // SRA
            set_reg(cpu, rd, (uint32_t)((int32_t)cpu->regs[rt] >> shamt));
            break;
        case 0x04: // SLLV
            set_reg(cpu, rd, cpu->regs[rt] << (cpu->regs[rs] & 0x1F));
            break;
        case 0x06: // SRLV
            set_reg(cpu, rd, cpu->regs[rt] >> (cpu->regs[rs] & 0x1F));
            break;
        case 0x07: // SRAV
            set_reg(cpu, rd, (uint32_t)((int32_t)cpu->regs[rt] >> (cpu->regs[rs] & 0x1F)));
            break;
        case 0x08: // JR
            jump(cpu, cpu->regs[rs]);
            break;
        case 0x09: // JALR
            set_reg(cpu, rd, cpu->next_pc);
            jump(cpu, cpu->regs[rs]);
            break;
        case 0x0C: // SYSCALL
            raise_exception(cpu, 0x20);
            break;
        case 0x0D: // BREAK
            raise_exception(cpu, 0x24);
            break;
        case 0x10: // MFHI
            set_reg(cpu, rd, cpu->hi);
            break;
        case 0x11: // MTHI
            cpu->hi = cpu->regs[rs];
            break;
        case 0x12: // MFLO
            set_reg(cpu, rd, cpu->lo);
            break;
        case 0x13: // MTLO
            cpu->lo = cpu->regs[rs];
            break;
        case 0x18: // MULT
            {
                int64_t result = (int64_t)(int32_t)cpu->regs[rs] * (int64_t)(int32_t)cpu->regs[rt];
                cpu->lo = (uint32_t)result;
                cpu->hi = (uint32_t)(result >> 32);
            }
            break;
        case 0x19: // MULTU
            {
                uint64_t result = (uint64_t)cpu->regs[rs] * (uint64_t)cpu->regs[rt];
                cpu->lo = (uint32_t)result;
                cpu->hi = (uint32_t)(result >> 32);
            }
            break;
        case 0x1A: // DIV
            if (cpu->regs[rt] != 0) {
                cpu->lo = (uint32_t)((int32_t)cpu->regs[rs] / (int32_t)cpu->regs[rt]);
                cpu->hi = (uint32_t)((int32_t)cpu->regs[rs] % (int32_t)cpu->regs[rt]);
            } else {
                cpu->lo = (cpu->regs[rs] & 0x80000000) ? 1 : 0xFFFFFFFF;
                cpu->hi = cpu->regs[rs];
            }
            break;
        case 0x1B: // DIVU
            if (cpu->regs[rt] != 0) {
                cpu->lo = cpu->regs[rs] / cpu->regs[rt];
                cpu->hi = cpu->regs[rs] % cpu->regs[rt];
            } else {
                cpu->lo = 0xFFFFFFFF;
                cpu->hi = cpu->regs[rs];
            }
            break;
        case 0x20: // ADD
            set_reg(cpu, rd, cpu->regs[rs] + cpu->regs[rt]);
            break;
        case 0x21: // ADDU
            set_reg(cpu, rd, cpu->regs[rs] + cpu->regs[rt]);
            break;
        case 0x22: // SUB
            set_reg(cpu, rd, cpu->regs[rs] - cpu->regs[rt]);
            break;
        case 0x23: // SUBU
            set_reg(cpu, rd, cpu->regs[rs] - cpu->regs[rt]);
            break;
        case 0x24: // AND
            set_reg(cpu, rd, cpu->regs[rs] & cpu->regs[rt]);
            break;
        case 0x25: // OR
            set_reg(cpu, rd, cpu->regs[rs] | cpu->regs[rt]);
            break;
        case 0x26: // XOR
            set_reg(cpu, rd, cpu->regs[rs] ^ cpu->regs[rt]);
            break;
        case 0x27: // NOR
            set_reg(cpu, rd, ~(cpu->regs[rs] | cpu->regs[rt]));
            break;
        case 0x2A: // SLT
            set_reg(cpu, rd, (int32_t)cpu->regs[rs] < (int32_t)cpu->regs[rt] ? 1 : 0);
            break;
        case 0x2B: // SLTU
            set_reg(cpu, rd, cpu->regs[rs] < cpu->regs[rt] ? 1 : 0);
            break;
    }
}

// BCONDZ instructions (opcode 0x01)
static void execute_bcondz(CPUState *cpu, uint32_t instruction) {
    uint32_t rs = RS(instruction);
    uint32_t rt = RT(instruction);
    int32_t imm = sign_extend16(IMM16(instruction)) << 2;
    int32_t val = (int32_t)cpu->regs[rs];
    bool link = (rt & 0x10) != 0;
    bool bgez = (rt & 0x01) != 0;

    bool condition = bgez ? (val >= 0) : (val < 0);

    if (link) {
        set_reg(cpu, 31, cpu->next_pc);
    }

    if (condition) {
        branch(cpu, imm);
    }
}

// Execute single instruction
static void execute(CPUState *cpu, uint32_t instruction) {
    if (instruction == 0) return; // NOP

    uint32_t opcode = OPCODE(instruction);
    uint32_t rs = RS(instruction);
    uint32_t rt = RT(instruction);
    uint32_t imm = IMM16(instruction);
    int32_t simm = sign_extend16(imm);

    switch (opcode) {
        case 0x00: execute_special(cpu, instruction); break;
        case 0x01: execute_bcondz(cpu, instruction); break;
        case 0x02: // J
            jump(cpu, (cpu->pc & 0xF0000000) | (IMM26(instruction) << 2));
            break;
        case 0x03: // JAL
            set_reg(cpu, 31, cpu->next_pc);
            jump(cpu, (cpu->pc & 0xF0000000) | (IMM26(instruction) << 2));
            break;
        case 0x04: // BEQ
            if (cpu->regs[rs] == cpu->regs[rt]) branch(cpu, simm << 2);
            break;
        case 0x05: // BNE
            if (cpu->regs[rs] != cpu->regs[rt]) branch(cpu, simm << 2);
            break;
        case 0x06: // BLEZ
            if ((int32_t)cpu->regs[rs] <= 0) branch(cpu, simm << 2);
            break;
        case 0x07: // BGTZ
            if ((int32_t)cpu->regs[rs] > 0) branch(cpu, simm << 2);
            break;
        case 0x08: // ADDI
            set_reg(cpu, rt, cpu->regs[rs] + simm);
            break;
        case 0x09: // ADDIU
            set_reg(cpu, rt, cpu->regs[rs] + simm);
            break;
        case 0x0A: // SLTI
            set_reg(cpu, rt, (int32_t)cpu->regs[rs] < simm ? 1 : 0);
            break;
        case 0x0B: // SLTIU
            set_reg(cpu, rt, cpu->regs[rs] < (uint32_t)simm ? 1 : 0);
            break;
        case 0x0C: // ANDI
            set_reg(cpu, rt, cpu->regs[rs] & imm);
            break;
        case 0x0D: // ORI
            set_reg(cpu, rt, cpu->regs[rs] | imm);
            break;
        case 0x0E: // XORI
            set_reg(cpu, rt, cpu->regs[rs] ^ imm);
            break;
        case 0x0F: // LUI
            set_reg(cpu, rt, imm << 16);
            break;
        case 0x10: // COP0
            execute_cop0(cpu, instruction);
            break;
        case 0x12: // COP2 (GTE) - stub
            break;
        case 0x20: // LB
            {
                uint32_t addr = cpu->regs[rs] + simm;
                int8_t val = (int8_t)mem_read8(cpu, addr);
                set_reg_delayed(cpu, rt, (uint32_t)(int32_t)val);
            }
            break;
        case 0x21: // LH
            {
                uint32_t addr = cpu->regs[rs] + simm;
                int16_t val = (int16_t)mem_read16(cpu, addr);
                set_reg_delayed(cpu, rt, (uint32_t)(int32_t)val);
            }
            break;
        case 0x22: // LWL
            {
                uint32_t addr = cpu->regs[rs] + simm;
                uint32_t aligned = addr & ~3;
                uint32_t mem = mem_read32(cpu, aligned);
                uint32_t reg = cpu->regs[rt];
                switch (addr & 3) {
                    case 0: reg = (reg & 0x00FFFFFF) | (mem << 24); break;
                    case 1: reg = (reg & 0x0000FFFF) | (mem << 16); break;
                    case 2: reg = (reg & 0x000000FF) | (mem << 8); break;
                    case 3: reg = mem; break;
                }
                set_reg_delayed(cpu, rt, reg);
            }
            break;
        case 0x23: // LW
            set_reg_delayed(cpu, rt, mem_read32(cpu, cpu->regs[rs] + simm));
            break;
        case 0x24: // LBU
            set_reg_delayed(cpu, rt, mem_read8(cpu, cpu->regs[rs] + simm));
            break;
        case 0x25: // LHU
            set_reg_delayed(cpu, rt, mem_read16(cpu, cpu->regs[rs] + simm));
            break;
        case 0x26: // LWR
            {
                uint32_t addr = cpu->regs[rs] + simm;
                uint32_t aligned = addr & ~3;
                uint32_t mem = mem_read32(cpu, aligned);
                uint32_t reg = cpu->regs[rt];
                switch (addr & 3) {
                    case 0: reg = mem; break;
                    case 1: reg = (reg & 0xFF000000) | (mem >> 8); break;
                    case 2: reg = (reg & 0xFFFF0000) | (mem >> 16); break;
                    case 3: reg = (reg & 0xFFFFFF00) | (mem >> 24); break;
                }
                set_reg_delayed(cpu, rt, reg);
            }
            break;
        case 0x28: // SB
            mem_write8(cpu, cpu->regs[rs] + simm, cpu->regs[rt] & 0xFF);
            break;
        case 0x29: // SH
            mem_write16(cpu, cpu->regs[rs] + simm, cpu->regs[rt] & 0xFFFF);
            break;
        case 0x2A: // SWL
            {
                uint32_t addr = cpu->regs[rs] + simm;
                uint32_t aligned = addr & ~3;
                uint32_t mem = mem_read32(cpu, aligned);
                uint32_t reg = cpu->regs[rt];
                switch (addr & 3) {
                    case 0: mem = (mem & 0xFFFFFF00) | (reg >> 24); break;
                    case 1: mem = (mem & 0xFFFF0000) | (reg >> 16); break;
                    case 2: mem = (mem & 0xFF000000) | (reg >> 8); break;
                    case 3: mem = reg; break;
                }
                mem_write32(cpu, aligned, mem);
            }
            break;
        case 0x2B: // SW
            mem_write32(cpu, cpu->regs[rs] + simm, cpu->regs[rt]);
            break;
        case 0x2E: // SWR
            {
                uint32_t addr = cpu->regs[rs] + simm;
                uint32_t aligned = addr & ~3;
                uint32_t mem = mem_read32(cpu, aligned);
                uint32_t reg = cpu->regs[rt];
                switch (addr & 3) {
                    case 0: mem = reg; break;
                    case 1: mem = (mem & 0x000000FF) | (reg << 8); break;
                    case 2: mem = (mem & 0x0000FFFF) | (reg << 16); break;
                    case 3: mem = (mem & 0x00FFFFFF) | (reg << 24); break;
                }
                mem_write32(cpu, aligned, mem);
            }
            break;
        default:
            rb_raise(cExecutionError, "Unknown opcode 0x%02X at PC=0x%08X", opcode, cpu->pc - 4);
    }
}

// Check for pending interrupts
static void check_interrupts(CPUState *cpu) {
    if (cpu->interrupts == Qnil) return;

    VALUE pending = rb_funcall(cpu->interrupts, rb_intern("pending?"), 0);
    if (RTEST(pending)) {
        rb_funcall(cpu->cop0, rb_intern("set_hardware_irq"), 1, Qtrue);
    } else {
        rb_funcall(cpu->cop0, rb_intern("set_hardware_irq"), 1, Qfalse);
    }

    VALUE irq_pending = rb_funcall(cpu->cop0, rb_intern("interrupt_pending?"), 0);
    if (RTEST(irq_pending)) {
        raise_exception(cpu, 0x00);
    }
}

// Single step
static VALUE cpu_step(VALUE self) {
    CPUState *cpu = get_cpu(self);

    // Check interrupts periodically
    cpu->interrupt_check_counter++;
    if (cpu->interrupt_check_counter >= cpu->interrupt_check_interval) {
        cpu->interrupt_check_counter = 0;
        check_interrupts(cpu);
    }

    // Save current PC
    cpu->current_pc = cpu->pc;

    // Fetch instruction
    uint32_t instruction = mem_read32(cpu, cpu->pc);

    // Track delay slot
    cpu->in_delay_slot = cpu->branch_pending;

    // Update PC
    cpu->pc = cpu->next_pc;
    cpu->next_pc = cpu->pc + 4;

    // Apply pending load
    if (cpu->load_delay_reg != 0) {
        cpu->regs[cpu->load_delay_reg] = cpu->load_delay_value;
        cpu->load_delay_reg = 0;
    }

    // Execute
    execute(cpu, instruction);

    // Handle branch delay
    if (cpu->branch_pending) {
        cpu->next_pc = cpu->branch_target;
        cpu->branch_pending = false;
    }

    return Qnil;
}

// Run multiple steps (optimized batch execution)
static VALUE cpu_run_steps(VALUE self, VALUE steps_val) {
    CPUState *cpu = get_cpu(self);
    uint32_t steps = NUM2UINT(steps_val);

    for (uint32_t i = 0; i < steps; i++) {
        // Check interrupts periodically
        cpu->interrupt_check_counter++;
        if (cpu->interrupt_check_counter >= cpu->interrupt_check_interval) {
            cpu->interrupt_check_counter = 0;
            check_interrupts(cpu);
        }

        // Save current PC
        cpu->current_pc = cpu->pc;

        // Fetch instruction
        uint32_t instruction = mem_read32(cpu, cpu->pc);

        // Track delay slot
        cpu->in_delay_slot = cpu->branch_pending;

        // Update PC
        cpu->pc = cpu->next_pc;
        cpu->next_pc = cpu->pc + 4;

        // Apply pending load
        if (cpu->load_delay_reg != 0) {
            cpu->regs[cpu->load_delay_reg] = cpu->load_delay_value;
            cpu->load_delay_reg = 0;
        }

        // Execute
        execute(cpu, instruction);

        // Handle branch delay
        if (cpu->branch_pending) {
            cpu->next_pc = cpu->branch_target;
            cpu->branch_pending = false;
        }
    }

    return UINT2NUM(steps);
}

// Allocate
static VALUE cpu_alloc(VALUE klass) {
    CPUState *cpu = ALLOC(CPUState);
    memset(cpu, 0, sizeof(CPUState));
    return TypedData_Wrap_Struct(klass, &cpu_data_type, cpu);
}

// Initialize
static VALUE cpu_initialize(VALUE self, VALUE memory, VALUE interrupts, VALUE cop0) {
    CPUState *cpu = get_cpu(self);

    // Store Ruby object references
    cpu->memory = memory;
    cpu->interrupts = interrupts;
    cpu->cop0 = cop0;

    // Prevent GC
    rb_gc_register_address(&cpu->memory);
    rb_gc_register_address(&cpu->interrupts);
    rb_gc_register_address(&cpu->cop0);

    // Initialize state
    cpu->pc = 0xBFC00000;  // BIOS entry point
    cpu->next_pc = cpu->pc + 4;
    cpu->interrupt_check_interval = 64;

    return self;
}

// Getters
static VALUE cpu_get_pc(VALUE self) { return UINT2NUM(get_cpu(self)->pc); }
static VALUE cpu_get_hi(VALUE self) { return UINT2NUM(get_cpu(self)->hi); }
static VALUE cpu_get_lo(VALUE self) { return UINT2NUM(get_cpu(self)->lo); }
static VALUE cpu_get_cop0(VALUE self) { return get_cpu(self)->cop0; }
static VALUE cpu_get_memory(VALUE self) { return get_cpu(self)->memory; }

static VALUE cpu_get_regs(VALUE self) {
    CPUState *cpu = get_cpu(self);
    VALUE arr = rb_ary_new_capa(32);
    for (int i = 0; i < 32; i++) {
        rb_ary_push(arr, UINT2NUM(cpu->regs[i]));
    }
    return arr;
}

// Setters for testing
static VALUE cpu_set_pc(VALUE self, VALUE val) {
    get_cpu(self)->pc = NUM2UINT(val);
    get_cpu(self)->next_pc = get_cpu(self)->pc + 4;
    return val;
}

static VALUE cpu_set_reg(VALUE self, VALUE idx, VALUE val) {
    uint32_t i = NUM2UINT(idx);
    if (i > 0 && i < 32) {
        get_cpu(self)->regs[i] = NUM2UINT(val);
    }
    return val;
}

// Dump registers for debugging
static VALUE cpu_dump_registers(VALUE self) {
    CPUState *cpu = get_cpu(self);
    char buf[2048];
    char *p = buf;

    p += sprintf(p, "Registers:\n");
    for (int i = 0; i < 32; i += 4) {
        p += sprintf(p, "R%-2d=%08X  R%-2d=%08X  R%-2d=%08X  R%-2d=%08X\n",
                     i, cpu->regs[i], i+1, cpu->regs[i+1],
                     i+2, cpu->regs[i+2], i+3, cpu->regs[i+3]);
    }
    p += sprintf(p, "PC=%08X  HI=%08X  LO=%08X\n", cpu->pc, cpu->hi, cpu->lo);

    return rb_str_new_cstr(buf);
}

// Extension initialization
void Init_psx_native(void) {
    VALUE mPSX = rb_define_module("PSX");

    cNativeCPU = rb_define_class_under(mPSX, "NativeCPU", rb_cObject);
    cExecutionError = rb_define_class_under(cNativeCPU, "ExecutionError", rb_eStandardError);

    rb_define_alloc_func(cNativeCPU, cpu_alloc);
    rb_define_method(cNativeCPU, "initialize", cpu_initialize, 3);
    rb_define_method(cNativeCPU, "step", cpu_step, 0);
    rb_define_method(cNativeCPU, "run_steps", cpu_run_steps, 1);

    rb_define_method(cNativeCPU, "pc", cpu_get_pc, 0);
    rb_define_method(cNativeCPU, "hi", cpu_get_hi, 0);
    rb_define_method(cNativeCPU, "lo", cpu_get_lo, 0);
    rb_define_method(cNativeCPU, "regs", cpu_get_regs, 0);
    rb_define_method(cNativeCPU, "cop0", cpu_get_cop0, 0);
    rb_define_method(cNativeCPU, "memory", cpu_get_memory, 0);

    rb_define_method(cNativeCPU, "pc=", cpu_set_pc, 1);
    rb_define_method(cNativeCPU, "set_reg", cpu_set_reg, 2);
    rb_define_method(cNativeCPU, "dump_registers", cpu_dump_registers, 0);
}
