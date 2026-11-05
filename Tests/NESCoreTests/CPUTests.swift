import Testing
@testable import NESCore

@Suite("6502 CPU")
struct CPUTests {
    /// Runs `program` followed by an infinite loop and returns the console once the loop is hit.
    func run(_ program: [UInt8]) throws -> NESConsole {
        let loopAddress = UInt16(0xC000 + program.count)
        let code = program + [0x4C, UInt8(loopAddress & 0xFF), UInt8(loopAddress >> 8)]
        let nes = try TestROM.console(code)
        #expect(nes.run(until: loopAddress))
        return nes
    }

    @Test func resetVectorAndInitialState() throws {
        let nes = try TestROM.console([0xEA])
        #expect(nes.cpu.pc == 0xC000)
        #expect(nes.cpu.s == 0xFD)
        #expect(nes.cpu.p & 0x04 != 0)   // I flag set
    }

    @Test func loadStoreAndTransfers() throws {
        let nes = try run([0xA9, 0x42, 0x85, 0x10, 0xA6, 0x10, 0x8A, 0xA8, 0x8C, 0x00, 0x03])
        #expect(nes.cpu.a == 0x42 && nes.cpu.x == 0x42 && nes.cpu.y == 0x42)
        #expect(nes.peek(0x0010) == 0x42)
        #expect(nes.peek(0x0300) == 0x42)
        #expect(nes.peek(0x0B00) == 0x42)   // $0800 mirror
    }

    @Test func adcOverflowAndCarry() throws {
        // CLC; LDA #$7F; ADC #$01 -> $80, V=1, C=0, N=1
        var nes = try run([0x18, 0xA9, 0x7F, 0x69, 0x01])
        #expect(nes.cpu.a == 0x80)
        #expect(nes.cpu.p & 0x40 != 0 && nes.cpu.p & 0x01 == 0 && nes.cpu.p & 0x80 != 0)
        // SEC; LDA #$00; SBC #$01 -> $FF, C=0 (borrow)
        nes = try run([0x38, 0xA9, 0x00, 0xE9, 0x01])
        #expect(nes.cpu.a == 0xFF && nes.cpu.p & 0x01 == 0)
        // CLC; LDA #$FF; ADC #$01 -> $00, C=1, Z=1
        nes = try run([0x18, 0xA9, 0xFF, 0x69, 0x01])
        #expect(nes.cpu.a == 0x00 && nes.cpu.p & 0x03 == 0x03)
    }

    @Test func decimalFlagIsIgnoredByADC() throws {
        // SED; CLC; LDA #$09; ADC #$01 -> $0A on the 2A03 (no BCD)
        let nes = try run([0xF8, 0x18, 0xA9, 0x09, 0x69, 0x01])
        #expect(nes.cpu.a == 0x0A)
        #expect(nes.cpu.p & 0x08 != 0)
    }

    @Test func jsrRtsAndStack() throws {
        // JSR $C010 ; at $C010: LDX #$07; RTS
        var program = [UInt8](repeating: 0xEA, count: 0x13)
        program[0] = 0x20; program[1] = 0x10; program[2] = 0xC0   // JSR
        program[3] = 0xA0; program[4] = 0x09                     // LDY #9
        program[5] = 0x4C; program[6] = 0x05; program[7] = 0xC0   // JMP $C005 (loop)
        program[0x10] = 0xA2; program[0x11] = 0x07; program[0x12] = 0x60
        let nes = try TestROM.console(program)
        #expect(nes.run(until: 0xC005))
        #expect(nes.cpu.x == 7 && nes.cpu.y == 9 && nes.cpu.s == 0xFD)
    }

    @Test func jmpIndirectPageWrapBug() throws {
        // Pointer at $02FF: low byte from $02FF, high byte from $0200 (not $0300).
        // $02FF = $20, $0200 = $C0, $0300 = $99: a correct 6502 jumps to $C020, not $9920.
        let setup: [UInt8] = [0xA9, 0x20, 0x8D, 0xFF, 0x02,   // $02FF = $20
                              0xA9, 0xC0, 0x8D, 0x00, 0x02,   // $0200 = $C0
                              0xA9, 0x99, 0x8D, 0x00, 0x03,   // $0300 = $99
                              0x6C, 0xFF, 0x02]               // JMP ($02FF)
        let padding = [UInt8](repeating: 0xEA, count: 0x20 - setup.count)
        let nes = try TestROM.console(setup + padding + [0xA2, 0x55, 0x4C, 0x22, 0xC0])   // $C020: LDX #$55; loop
        #expect(nes.run(until: 0xC022))
        #expect(nes.cpu.x == 0x55)
    }

    @Test func instructionCycleCounts() throws {
        func cycles(_ program: [UInt8], setup: [UInt8] = []) throws -> UInt64 {
            let nes = try TestROM.console(setup + program + [0xEA])
            let start = UInt16(0xC000 + setup.count)
            #expect(nes.run(until: start))
            let before = nes.cpu.cycleCount
            nes.cpu.step()
            return nes.cpu.cycleCount - before
        }
        #expect(try cycles([0xA9, 0x00]) == 2)                                  // LDA #
        #expect(try cycles([0xAD, 0x00, 0x03]) == 4)                            // LDA abs
        #expect(try cycles([0xBD, 0xFF, 0x03], setup: [0xA2, 0x01]) == 5)       // LDA abs,X page cross
        #expect(try cycles([0xBD, 0x00, 0x03], setup: [0xA2, 0x01]) == 4)       // LDA abs,X no cross
        #expect(try cycles([0x9D, 0x00, 0x03], setup: [0xA2, 0x01]) == 5)       // STA abs,X always 5
        #expect(try cycles([0xFE, 0x00, 0x03], setup: [0xA2, 0x01]) == 7)       // INC abs,X
        #expect(try cycles([0x20, 0x00, 0xC1]) == 6)                            // JSR
        #expect(try cycles([0x48]) == 3)                                        // PHA
        #expect(try cycles([0x68]) == 4)                                        // PLA
        #expect(try cycles([0xB1, 0x10], setup: [0xA0, 0x01, 0xA9, 0xFF, 0x85, 0x10, 0xA9, 0x02, 0x85, 0x11]) == 6) // (zp),Y cross
        #expect(try cycles([0xD0, 0x02], setup: [0xA9, 0x01]) == 3)             // BNE taken
        #expect(try cycles([0xF0, 0x02], setup: [0xA9, 0x01]) == 2)             // BEQ not taken
    }

    @Test func unofficialOpcodes() throws {
        // LAX $10 ; SAX $11 (A&X) ; DCP $12 ; ISC $13
        let nes = try run([0xA9, 0xF0, 0x85, 0x10, 0xA9, 0x05, 0x85, 0x12, 0xA9, 0x10, 0x85, 0x13,
                           0xA7, 0x10,              // LAX $10 -> A=X=$F0
                           0xA2, 0x3C, 0x87, 0x11,  // LDX #$3C; SAX $11 -> $F0 & $3C = $30
                           0xC7, 0x12,              // DCP $12 -> $04, compare A($F0) with $04
                           0x38, 0xE7, 0x13])       // SEC; ISC $13 -> $11, A = $F0 - $11 = $DF
        #expect(nes.peek(0x0011) == 0x30)
        #expect(nes.peek(0x0012) == 0x04)
        #expect(nes.peek(0x0013) == 0x11)
        #expect(nes.cpu.a == 0xDF)
    }

    @Test func brkAndRti() throws {
        // BRK jumps to the IRQ vector ($F800): handler sets X=$66 then RTI back to after BRK's padding.
        let nes = try TestROM.console([0x58, 0x00, 0xEA, 0xA0, 0x11, 0x4C, 0x05, 0xC0],
                                      irq: [0xA2, 0x66, 0x40])
        #expect(nes.run(until: 0xC005))
        #expect(nes.cpu.x == 0x66 && nes.cpu.y == 0x11)
    }

    @Test func jamHaltsTheCPU() throws {
        let nes = try TestROM.console([0x02])
        nes.step(instructions: 3)
        #expect(nes.cpu.jammed)
        nes.runFrame()   // must not hang
    }

    @Test func nmiFiresOnVBlank() throws {
        // Enable NMI; the handler increments $20.
        let nes = try TestROM.console([0xA9, 0x80, 0x8D, 0x00, 0x20, 0x4C, 0x05, 0xC0],
                                      nmi: [0xE6, 0x20, 0x40])
        for _ in 0..<5 { nes.runFrame() }
        #expect(nes.peek(0x0020) >= 4)
    }

    @Test func apuFrameIRQ() throws {
        // CLI with the frame counter in 4-step mode raises an IRQ; handler acknowledges via $4015.
        let nes = try TestROM.console([0x58, 0x4C, 0x01, 0xC0], irq: [0xAD, 0x15, 0x40, 0xE6, 0x30, 0x40])
        for _ in 0..<4 { nes.runFrame() }
        #expect(nes.peek(0x0030) >= 3)
    }
}
