/// Ricoh 2A03 CPU core (6502 without decimal mode) plus the CPU address bus.
///
/// Every bus access is one CPU cycle; the PPU, APU and mapper are advanced from inside
/// each access, so mid-instruction timing (sprite 0 polling, $2002 races, DMA stalls,
/// IRQ edges) behaves like the hardware.
public final class CPU {
    // Registers
    public internal(set) var a: UInt8 = 0
    public internal(set) var x: UInt8 = 0
    public internal(set) var y: UInt8 = 0
    public internal(set) var s: UInt8 = 0xFD
    public internal(set) var pc: UInt16 = 0
    var fC = false, fZ = false, fI = true, fD = false, fV = false, fN = false

    public var p: UInt8 {
        get {
            var v: UInt8 = 0x20
            if fC { v |= 0x01 }
            if fZ { v |= 0x02 }
            if fI { v |= 0x04 }
            if fD { v |= 0x08 }
            if fV { v |= 0x40 }
            if fN { v |= 0x80 }
            return v
        }
        set {
            fC = (newValue & 0x01) != 0
            fZ = (newValue & 0x02) != 0
            fI = (newValue & 0x04) != 0
            fD = (newValue & 0x08) != 0
            fV = (newValue & 0x40) != 0
            fN = (newValue & 0x80) != 0
        }
    }

    // Timing
    public internal(set) var cycleCount: UInt64 = 0
    var masterClock: UInt64 = 0
    let startReadClocks: UInt64, endReadClocks: UInt64
    let startWriteClocks: UInt64, endWriteClocks: UInt64
    let ppuOffset: UInt64 = 1

    // Interrupts
    var prevNMILine = false
    var needNMI = false
    var prevNeedNMI = false
    var runIRQ = false
    var prevRunIRQ = false
    public internal(set) var jammed = false

    // DMA
    var needHalt = false
    var needDummyRead = false
    var dmcDMARunning = false
    var spriteDMATransfer = false
    var spriteDMAPage: UInt8 = 0

    // Bus
    let ram = ByteBuffer(count: 0x800)
    let ramPointer: UnsafeMutablePointer<UInt8>
    var openBus: UInt8 = 0
    let ppu: PPU
    let apu: APU
    let mapper: Mapper
    let input: InputPorts
    let mapperNeedsClock: Bool
    var cheats: CheatEngine?

    init(region: Region, ppu: PPU, apu: APU, mapper: Mapper, input: InputPorts) {
        self.ppu = ppu
        self.apu = apu
        self.mapper = mapper
        self.input = input
        mapperNeedsClock = mapper.needsCPUClock
        ramPointer = ram.pointer
        // A CPU cycle is split around the PPU so register reads land mid-cycle.
        let half = region.cpuDivider / 2
        let start = half, end = region.cpuDivider - half
        startReadClocks = start - 1
        endReadClocks = end + 1
        startWriteClocks = start + 1
        endWriteClocks = end - 1
    }

    // MARK: - Reset

    func powerOn() {
        a = 0; x = 0; y = 0; s = 0xFD
        p = 0x24
        jammed = false
        needNMI = false; prevNeedNMI = false; runIRQ = false; prevRunIRQ = false
        prevNMILine = false
        needHalt = false; needDummyRead = false; dmcDMARunning = false; spriteDMATransfer = false
        resetSequence()
    }

    func reset() {
        s &-= 3
        fI = true
        jammed = false
        needNMI = false; prevNeedNMI = false
        needHalt = false; needDummyRead = false; dmcDMARunning = false; spriteDMATransfer = false
        resetSequence()
    }

    private func resetSequence() {
        // Five idle cycles, then the vector fetch.
        for _ in 0..<5 {
            startCycle(forRead: true)
            endCycle(forRead: true)
        }
        let lo = read(0xFFFC), hi = read(0xFFFD)
        pc = UInt16(hi) << 8 | UInt16(lo)
    }

    // MARK: - Cycle plumbing

    @inline(__always)
    func startCycle(forRead: Bool) {
        masterClock &+= forRead ? startReadClocks : startWriteClocks
        cycleCount &+= 1
        ppu.run(until: masterClock &- ppuOffset)
        apu.clock()
        if apu.dmcDMARequest {
            apu.dmcDMARequest = false
            startDMCTransfer()
        }
        if mapperNeedsClock { mapper.clockCPU() }
    }

    @inline(__always)
    func endCycle(forRead: Bool) {
        masterClock &+= forRead ? endReadClocks : endWriteClocks
        ppu.run(until: masterClock &- ppuOffset)
        // NMI is edge triggered: detected during φ2, acted on from the next cycle.
        prevNeedNMI = needNMI
        let nmiLine = ppu.nmiOutput
        if !prevNMILine && nmiLine { needNMI = true }
        prevNMILine = nmiLine
        // IRQ is level triggered and sampled at the end of the second-to-last cycle.
        prevRunIRQ = runIRQ
        runIRQ = (apu.irq || mapper.irqLine) && !fI
    }

    @inline(__always)
    func read(_ address: UInt16) -> UInt8 {
        if needHalt { processPendingDMA(address) }
        startCycle(forRead: true)
        let v = busRead(address)
        endCycle(forRead: true)
        return v
    }

    @inline(__always)
    func write(_ address: UInt16, _ value: UInt8) {
        startCycle(forRead: false)
        busWrite(address, value)
        endCycle(forRead: false)
    }

    @inline(__always)
    func dummyRead(_ address: UInt16) {
        _ = read(address)
    }

    // MARK: - Bus

    @inline(__always)
    func busRead(_ address: UInt16) -> UInt8 {
        let addr = Int(address)
        var value: UInt8
        switch addr >> 13 {
        case 0:
            value = ramPointer[addr & 0x7FF]
        case 1:
            value = ppu.readRegister(addr & 7)
        case 2:
            if addr < 0x4020 {
                switch addr {
                case 0x4015:
                    // Reading $4015 does not drive the data bus; bit 5 is open bus.
                    return apu.readStatus() | (openBus & 0x20)
                case 0x4016:
                    value = (input.read(port: 0) & 0x1F) | (openBus & 0xE0)
                case 0x4017:
                    value = (input.read(port: 1) & 0x1F) | (openBus & 0xE0)
                default:
                    value = openBus
                }
            } else {
                value = mapper.readCPU(addr, openBus: openBus)
            }
        default:
            value = mapper.readCPU(addr, openBus: openBus)
        }
        if let cheats, addr >= 0x6000 { value = cheats.patch(address: addr, value: value) }
        openBus = value
        return value
    }

    @inline(__always)
    func busWrite(_ address: UInt16, _ value: UInt8) {
        let addr = Int(address)
        openBus = value
        switch addr >> 13 {
        case 0:
            ramPointer[addr & 0x7FF] = value
        case 1:
            ppu.writeRegister(addr & 7, value)
        case 2:
            if addr < 0x4020 {
                switch addr {
                case 0x4014:
                    spriteDMATransfer = true
                    spriteDMAPage = value
                    needHalt = true
                case 0x4016:
                    input.write(value)
                default:
                    if addr <= 0x4017 { apu.write(addr, value) }
                }
            } else {
                mapper.writeCPU(addr, value)
            }
        default:
            mapper.writeCPU(addr, value)
        }
    }

    /// Side-effect-free read of the CPU address space.
    public func peek(_ address: UInt16) -> UInt8 {
        let addr = Int(address)
        switch addr >> 13 {
        case 0: return ram[addr & 0x7FF]
        case 1:
            switch addr & 7 {
            case 2:
                return (ppu.vblank ? 0x80 : 0) | (ppu.sprite0Hit ? 0x40 : 0) | (ppu.spriteOverflow ? 0x20 : 0)
            case 4: return ppu.oam[Int(ppu.oamAddr)]
            default: return ppu.openBus
            }
        case 2 where addr < 0x4020:
            return addr == 0x4015 ? apu.peekStatus() : 0
        default:
            return mapper.peekCPU(addr)
        }
    }

    // MARK: - DMA

    func startDMCTransfer() {
        dmcDMARunning = true
        needDummyRead = true
        needHalt = true
    }

    @inline(__always)
    private func dmaCycle() {
        if needHalt {
            needHalt = false
        } else if needDummyRead {
            needDummyRead = false
        }
        startCycle(forRead: true)
    }

    private func processPendingDMA(_ readAddress: UInt16) {
        // Halt cycle: the CPU repeats the read it was about to do.
        startCycle(forRead: true)
        needHalt = false
        _ = busRead(readAddress)
        endCycle(forRead: true)

        // Repeated reads of $4016/$4017 would clock the controller shift registers; the
        // hardware's DMA unit does not repeat those reads, so neither do we.
        let skipDummyReads = readAddress == 0x4016 || readAddress == 0x4017
        var spriteCounter = 0
        var spriteAddress: UInt8 = 0
        var spriteValue: UInt8 = 0

        while dmcDMARunning || spriteDMATransfer {
            let getCycle = (cycleCount & 1) == 0
            if getCycle {
                if dmcDMARunning && !needHalt && !needDummyRead {
                    // DMC fetch
                    dmaCycle()
                    let v = busRead(UInt16(truncatingIfNeeded: apu.dmcDMAAddress))
                    endCycle(forRead: true)
                    dmcDMARunning = false
                    apu.setDMCBuffer(v)
                } else if spriteDMATransfer {
                    // Sprite read
                    dmaCycle()
                    spriteValue = busRead(UInt16(spriteDMAPage) << 8 | UInt16(spriteAddress))
                    endCycle(forRead: true)
                    spriteAddress &+= 1
                    spriteCounter += 1
                } else {
                    // DMC halt/dummy cycle
                    dmaCycle()
                    if !skipDummyReads { _ = busRead(readAddress) }
                    endCycle(forRead: true)
                }
            } else {
                if spriteDMATransfer && (spriteCounter & 1) == 1 {
                    // Sprite write
                    dmaCycle()
                    ppu.writeOAMDMA(spriteValue)
                    endCycle(forRead: true)
                    spriteCounter += 1
                    if spriteCounter == 0x200 { spriteDMATransfer = false }
                } else {
                    // Alignment cycle
                    dmaCycle()
                    if !skipDummyReads { _ = busRead(readAddress) }
                    endCycle(forRead: true)
                }
            }
        }
    }

    // MARK: - Execution

    /// Executes one instruction (and services a pending interrupt afterwards).
    @inline(__always)
    func step() {
        if jammed {
            startCycle(forRead: true)
            endCycle(forRead: true)
            return
        }
        let opcode = read(pc)
        pc &+= 1
        execute(opcode)
        if prevRunIRQ || prevNeedNMI {
            interrupt()
        }
    }

    func interrupt() {
        dummyRead(pc)
        dummyRead(pc)
        push(UInt8(pc >> 8))
        push(UInt8(pc & 0xFF))
        if needNMI {
            needNMI = false
            push(p & ~0x10)
            fI = true
            pc = readVector(0xFFFA)
        } else {
            push(p & ~0x10)
            fI = true
            pc = readVector(0xFFFE)
        }
    }

    @inline(__always)
    func readVector(_ address: UInt16) -> UInt16 {
        let lo = read(address)
        let hi = read(address &+ 1)
        return UInt16(hi) << 8 | UInt16(lo)
    }

    // MARK: Stack & flags

    @inline(__always) func push(_ v: UInt8) { write(0x100 | UInt16(s), v); s &-= 1 }
    @inline(__always) func pop() -> UInt8 { s &+= 1; return read(0x100 | UInt16(s)) }
    @inline(__always) func setZN(_ v: UInt8) { fZ = v == 0; fN = (v & 0x80) != 0 }

    // MARK: Addressing

    @inline(__always) func fetch() -> UInt8 { let v = read(pc); pc &+= 1; return v }
    @inline(__always) func fetch16() -> UInt16 { let lo = fetch(); let hi = fetch(); return UInt16(hi) << 8 | UInt16(lo) }

    @inline(__always) func addrZP() -> UInt16 { UInt16(fetch()) }
    @inline(__always) func addrZPX() -> UInt16 { let b = fetch(); dummyRead(UInt16(b)); return UInt16(b &+ x) }
    @inline(__always) func addrZPY() -> UInt16 { let b = fetch(); dummyRead(UInt16(b)); return UInt16(b &+ y) }
    @inline(__always) func addrAbs() -> UInt16 { fetch16() }

    @inline(__always) func addrAbsIndexed(_ index: UInt8, write: Bool) -> UInt16 {
        let base = fetch16()
        let addr = base &+ UInt16(index)
        if write || (base ^ addr) & 0xFF00 != 0 {
            dummyRead((base & 0xFF00) | (addr & 0x00FF))
        }
        return addr
    }

    @inline(__always) func addrIndX() -> UInt16 {
        let zp = fetch()
        dummyRead(UInt16(zp))
        let ptr = zp &+ x
        let lo = read(UInt16(ptr))
        let hi = read(UInt16(ptr &+ 1))
        return UInt16(hi) << 8 | UInt16(lo)
    }

    @inline(__always) func addrIndY(write: Bool) -> UInt16 {
        let zp = fetch()
        let lo = read(UInt16(zp))
        let hi = read(UInt16(zp &+ 1))
        let base = UInt16(hi) << 8 | UInt16(lo)
        let addr = base &+ UInt16(y)
        if write || (base ^ addr) & 0xFF00 != 0 {
            dummyRead((base & 0xFF00) | (addr & 0x00FF))
        }
        return addr
    }

    /// Base address and final address for SHx-style instructions.
    @inline(__always) func addrAbsIndexedRaw(_ index: UInt8) -> (UInt16, UInt16) {
        let base = fetch16()
        let addr = base &+ UInt16(index)
        dummyRead((base & 0xFF00) | (addr & 0x00FF))
        return (base, addr)
    }

    // MARK: ALU

    @inline(__always) func adc(_ v: UInt8) {
        let sum = UInt16(a) &+ UInt16(v) &+ (fC ? 1 : 0)
        let result = UInt8(truncatingIfNeeded: sum)
        fV = (~(a ^ v) & (a ^ result) & 0x80) != 0
        fC = sum > 0xFF
        a = result
        setZN(a)
    }

    @inline(__always) func sbc(_ v: UInt8) { adc(~v) }

    @inline(__always) func compare(_ reg: UInt8, _ v: UInt8) {
        fC = reg >= v
        setZN(reg &- v)
    }

    @inline(__always) func asl(_ v: UInt8) -> UInt8 { fC = (v & 0x80) != 0; let r = v << 1; setZN(r); return r }
    @inline(__always) func lsr(_ v: UInt8) -> UInt8 { fC = (v & 0x01) != 0; let r = v >> 1; setZN(r); return r }
    @inline(__always) func rol(_ v: UInt8) -> UInt8 {
        let r = v << 1 | (fC ? 1 : 0); fC = (v & 0x80) != 0; setZN(r); return r
    }
    @inline(__always) func ror(_ v: UInt8) -> UInt8 {
        let r = v >> 1 | (fC ? 0x80 : 0); fC = (v & 0x01) != 0; setZN(r); return r
    }

    /// Read-modify-write: read, write the old value back (dummy write), then write the result.
    @inline(__always) func rmw(_ address: UInt16, _ op: (UInt8) -> UInt8) {
        let v = read(address)
        write(address, v)
        write(address, op(v))
    }

    @inline(__always) func branch(_ condition: Bool) {
        let offset = Int8(bitPattern: fetch())
        guard condition else { return }
        dummyRead(pc)
        let target = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(offset))
        if (target ^ pc) & 0xFF00 != 0 {
            dummyRead((pc & 0xFF00) | (target & 0x00FF))
        } else if runIRQ && !prevRunIRQ {
            // A taken branch without page crossing delays an IRQ that arrived during it.
            runIRQ = false
        }
        pc = target
    }

    /// SHA/SHX/SHY/TAS store: value is reg & (high byte of base + 1); a page cross corrupts the address.
    @inline(__always) func storeUnstable(base: UInt16, address: UInt16, value reg: UInt8) {
        let crossed = (base ^ address) & 0xFF00 != 0
        let high = UInt8(truncatingIfNeeded: base >> 8) &+ 1
        let value = reg & high
        let target = crossed ? (UInt16(value) << 8) | (address & 0x00FF) : address
        write(target, value)
    }

    // MARK: Opcodes

    @inline(__always)
    func execute(_ opcode: UInt8) {
        switch opcode {
        // MARK: Loads
        case 0xA9: a = fetch(); setZN(a)
        case 0xA5: a = read(addrZP()); setZN(a)
        case 0xB5: a = read(addrZPX()); setZN(a)
        case 0xAD: a = read(addrAbs()); setZN(a)
        case 0xBD: a = read(addrAbsIndexed(x, write: false)); setZN(a)
        case 0xB9: a = read(addrAbsIndexed(y, write: false)); setZN(a)
        case 0xA1: a = read(addrIndX()); setZN(a)
        case 0xB1: a = read(addrIndY(write: false)); setZN(a)

        case 0xA2: x = fetch(); setZN(x)
        case 0xA6: x = read(addrZP()); setZN(x)
        case 0xB6: x = read(addrZPY()); setZN(x)
        case 0xAE: x = read(addrAbs()); setZN(x)
        case 0xBE: x = read(addrAbsIndexed(y, write: false)); setZN(x)

        case 0xA0: y = fetch(); setZN(y)
        case 0xA4: y = read(addrZP()); setZN(y)
        case 0xB4: y = read(addrZPX()); setZN(y)
        case 0xAC: y = read(addrAbs()); setZN(y)
        case 0xBC: y = read(addrAbsIndexed(x, write: false)); setZN(y)

        // MARK: Stores
        case 0x85: write(addrZP(), a)
        case 0x95: write(addrZPX(), a)
        case 0x8D: write(addrAbs(), a)
        case 0x9D: write(addrAbsIndexed(x, write: true), a)
        case 0x99: write(addrAbsIndexed(y, write: true), a)
        case 0x81: write(addrIndX(), a)
        case 0x91: write(addrIndY(write: true), a)
        case 0x86: write(addrZP(), x)
        case 0x96: write(addrZPY(), x)
        case 0x8E: write(addrAbs(), x)
        case 0x84: write(addrZP(), y)
        case 0x94: write(addrZPX(), y)
        case 0x8C: write(addrAbs(), y)

        // MARK: Transfers
        case 0xAA: dummyRead(pc); x = a; setZN(x)
        case 0xA8: dummyRead(pc); y = a; setZN(y)
        case 0x8A: dummyRead(pc); a = x; setZN(a)
        case 0x98: dummyRead(pc); a = y; setZN(a)
        case 0xBA: dummyRead(pc); x = s; setZN(x)
        case 0x9A: dummyRead(pc); s = x

        // MARK: Stack
        case 0x48: dummyRead(pc); push(a)
        case 0x08: dummyRead(pc); push(p | 0x10)
        case 0x68: dummyRead(pc); dummyRead(0x100 | UInt16(s)); a = pop(); setZN(a)
        case 0x28: dummyRead(pc); dummyRead(0x100 | UInt16(s)); p = pop()

        // MARK: Logic / arithmetic
        case 0x29: a &= fetch(); setZN(a)
        case 0x25: a &= read(addrZP()); setZN(a)
        case 0x35: a &= read(addrZPX()); setZN(a)
        case 0x2D: a &= read(addrAbs()); setZN(a)
        case 0x3D: a &= read(addrAbsIndexed(x, write: false)); setZN(a)
        case 0x39: a &= read(addrAbsIndexed(y, write: false)); setZN(a)
        case 0x21: a &= read(addrIndX()); setZN(a)
        case 0x31: a &= read(addrIndY(write: false)); setZN(a)

        case 0x09: a |= fetch(); setZN(a)
        case 0x05: a |= read(addrZP()); setZN(a)
        case 0x15: a |= read(addrZPX()); setZN(a)
        case 0x0D: a |= read(addrAbs()); setZN(a)
        case 0x1D: a |= read(addrAbsIndexed(x, write: false)); setZN(a)
        case 0x19: a |= read(addrAbsIndexed(y, write: false)); setZN(a)
        case 0x01: a |= read(addrIndX()); setZN(a)
        case 0x11: a |= read(addrIndY(write: false)); setZN(a)

        case 0x49: a ^= fetch(); setZN(a)
        case 0x45: a ^= read(addrZP()); setZN(a)
        case 0x55: a ^= read(addrZPX()); setZN(a)
        case 0x4D: a ^= read(addrAbs()); setZN(a)
        case 0x5D: a ^= read(addrAbsIndexed(x, write: false)); setZN(a)
        case 0x59: a ^= read(addrAbsIndexed(y, write: false)); setZN(a)
        case 0x41: a ^= read(addrIndX()); setZN(a)
        case 0x51: a ^= read(addrIndY(write: false)); setZN(a)

        case 0x69: adc(fetch())
        case 0x65: adc(read(addrZP()))
        case 0x75: adc(read(addrZPX()))
        case 0x6D: adc(read(addrAbs()))
        case 0x7D: adc(read(addrAbsIndexed(x, write: false)))
        case 0x79: adc(read(addrAbsIndexed(y, write: false)))
        case 0x61: adc(read(addrIndX()))
        case 0x71: adc(read(addrIndY(write: false)))

        case 0xE9, 0xEB: sbc(fetch())
        case 0xE5: sbc(read(addrZP()))
        case 0xF5: sbc(read(addrZPX()))
        case 0xED: sbc(read(addrAbs()))
        case 0xFD: sbc(read(addrAbsIndexed(x, write: false)))
        case 0xF9: sbc(read(addrAbsIndexed(y, write: false)))
        case 0xE1: sbc(read(addrIndX()))
        case 0xF1: sbc(read(addrIndY(write: false)))

        case 0xC9: compare(a, fetch())
        case 0xC5: compare(a, read(addrZP()))
        case 0xD5: compare(a, read(addrZPX()))
        case 0xCD: compare(a, read(addrAbs()))
        case 0xDD: compare(a, read(addrAbsIndexed(x, write: false)))
        case 0xD9: compare(a, read(addrAbsIndexed(y, write: false)))
        case 0xC1: compare(a, read(addrIndX()))
        case 0xD1: compare(a, read(addrIndY(write: false)))
        case 0xE0: compare(x, fetch())
        case 0xE4: compare(x, read(addrZP()))
        case 0xEC: compare(x, read(addrAbs()))
        case 0xC0: compare(y, fetch())
        case 0xC4: compare(y, read(addrZP()))
        case 0xCC: compare(y, read(addrAbs()))

        case 0x24, 0x2C:
            let v = read(opcode == 0x24 ? addrZP() : addrAbs())
            fZ = (a & v) == 0
            fV = (v & 0x40) != 0
            fN = (v & 0x80) != 0

        // MARK: Increments
        case 0xE8: dummyRead(pc); x &+= 1; setZN(x)
        case 0xC8: dummyRead(pc); y &+= 1; setZN(y)
        case 0xCA: dummyRead(pc); x &-= 1; setZN(x)
        case 0x88: dummyRead(pc); y &-= 1; setZN(y)
        case 0xE6: rmw(addrZP()) { v in let r = v &+ 1; self.setZN(r); return r }
        case 0xF6: rmw(addrZPX()) { v in let r = v &+ 1; self.setZN(r); return r }
        case 0xEE: rmw(addrAbs()) { v in let r = v &+ 1; self.setZN(r); return r }
        case 0xFE: rmw(addrAbsIndexed(x, write: true)) { v in let r = v &+ 1; self.setZN(r); return r }
        case 0xC6: rmw(addrZP()) { v in let r = v &- 1; self.setZN(r); return r }
        case 0xD6: rmw(addrZPX()) { v in let r = v &- 1; self.setZN(r); return r }
        case 0xCE: rmw(addrAbs()) { v in let r = v &- 1; self.setZN(r); return r }
        case 0xDE: rmw(addrAbsIndexed(x, write: true)) { v in let r = v &- 1; self.setZN(r); return r }

        // MARK: Shifts
        case 0x0A: dummyRead(pc); a = asl(a)
        case 0x4A: dummyRead(pc); a = lsr(a)
        case 0x2A: dummyRead(pc); a = rol(a)
        case 0x6A: dummyRead(pc); a = ror(a)
        case 0x06: rmw(addrZP(), asl)
        case 0x16: rmw(addrZPX(), asl)
        case 0x0E: rmw(addrAbs(), asl)
        case 0x1E: rmw(addrAbsIndexed(x, write: true), asl)
        case 0x46: rmw(addrZP(), lsr)
        case 0x56: rmw(addrZPX(), lsr)
        case 0x4E: rmw(addrAbs(), lsr)
        case 0x5E: rmw(addrAbsIndexed(x, write: true), lsr)
        case 0x26: rmw(addrZP(), rol)
        case 0x36: rmw(addrZPX(), rol)
        case 0x2E: rmw(addrAbs(), rol)
        case 0x3E: rmw(addrAbsIndexed(x, write: true), rol)
        case 0x66: rmw(addrZP(), ror)
        case 0x76: rmw(addrZPX(), ror)
        case 0x6E: rmw(addrAbs(), ror)
        case 0x7E: rmw(addrAbsIndexed(x, write: true), ror)

        // MARK: Flags
        case 0x18: dummyRead(pc); fC = false
        case 0x38: dummyRead(pc); fC = true
        case 0x58: dummyRead(pc); fI = false
        case 0x78: dummyRead(pc); fI = true
        case 0xB8: dummyRead(pc); fV = false
        case 0xD8: dummyRead(pc); fD = false
        case 0xF8: dummyRead(pc); fD = true

        // MARK: Branches
        case 0x10: branch(!fN)
        case 0x30: branch(fN)
        case 0x50: branch(!fV)
        case 0x70: branch(fV)
        case 0x90: branch(!fC)
        case 0xB0: branch(fC)
        case 0xD0: branch(!fZ)
        case 0xF0: branch(fZ)

        // MARK: Jumps
        case 0x4C:
            pc = fetch16()
        case 0x6C:
            let ptr = fetch16()
            let lo = read(ptr)
            let hi = read((ptr & 0xFF00) | UInt16(UInt8(truncatingIfNeeded: ptr) &+ 1))   // page-wrap bug
            pc = UInt16(hi) << 8 | UInt16(lo)
        case 0x20:
            let lo = fetch()
            dummyRead(0x100 | UInt16(s))
            push(UInt8(pc >> 8))
            push(UInt8(pc & 0xFF))
            let hi = read(pc)
            pc = UInt16(hi) << 8 | UInt16(lo)
        case 0x60:
            dummyRead(pc)
            dummyRead(0x100 | UInt16(s))
            let lo = pop(), hi = pop()
            pc = UInt16(hi) << 8 | UInt16(lo)
            dummyRead(pc)
            pc &+= 1
        case 0x40:
            dummyRead(pc)
            dummyRead(0x100 | UInt16(s))
            p = pop()
            let lo = pop(), hi = pop()
            pc = UInt16(hi) << 8 | UInt16(lo)
        case 0x00:
            _ = fetch()   // padding byte
            push(UInt8(pc >> 8))
            push(UInt8(pc & 0xFF))
            let flags = p | 0x30
            if needNMI {
                needNMI = false
                push(flags)
                fI = true
                pc = readVector(0xFFFA)
            } else {
                push(flags)
                fI = true
                pc = readVector(0xFFFE)
            }
            // The first handler instruction always runs before another NMI is taken.
            prevNeedNMI = false

        // MARK: NOPs
        case 0xEA, 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA: dummyRead(pc)
        case 0x80, 0x82, 0x89, 0xC2, 0xE2: _ = fetch()
        case 0x04, 0x44, 0x64: _ = read(addrZP())
        case 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4: _ = read(addrZPX())
        case 0x0C: _ = read(addrAbs())
        case 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC: _ = read(addrAbsIndexed(x, write: false))

        // MARK: Unofficial combined ops
        case 0x07: rmw(addrZP(), slo)
        case 0x17: rmw(addrZPX(), slo)
        case 0x0F: rmw(addrAbs(), slo)
        case 0x1F: rmw(addrAbsIndexed(x, write: true), slo)
        case 0x1B: rmw(addrAbsIndexed(y, write: true), slo)
        case 0x03: rmw(addrIndX(), slo)
        case 0x13: rmw(addrIndY(write: true), slo)

        case 0x27: rmw(addrZP(), rla)
        case 0x37: rmw(addrZPX(), rla)
        case 0x2F: rmw(addrAbs(), rla)
        case 0x3F: rmw(addrAbsIndexed(x, write: true), rla)
        case 0x3B: rmw(addrAbsIndexed(y, write: true), rla)
        case 0x23: rmw(addrIndX(), rla)
        case 0x33: rmw(addrIndY(write: true), rla)

        case 0x47: rmw(addrZP(), sre)
        case 0x57: rmw(addrZPX(), sre)
        case 0x4F: rmw(addrAbs(), sre)
        case 0x5F: rmw(addrAbsIndexed(x, write: true), sre)
        case 0x5B: rmw(addrAbsIndexed(y, write: true), sre)
        case 0x43: rmw(addrIndX(), sre)
        case 0x53: rmw(addrIndY(write: true), sre)

        case 0x67: rmw(addrZP(), rra)
        case 0x77: rmw(addrZPX(), rra)
        case 0x6F: rmw(addrAbs(), rra)
        case 0x7F: rmw(addrAbsIndexed(x, write: true), rra)
        case 0x7B: rmw(addrAbsIndexed(y, write: true), rra)
        case 0x63: rmw(addrIndX(), rra)
        case 0x73: rmw(addrIndY(write: true), rra)

        case 0xC7: rmw(addrZP(), dcp)
        case 0xD7: rmw(addrZPX(), dcp)
        case 0xCF: rmw(addrAbs(), dcp)
        case 0xDF: rmw(addrAbsIndexed(x, write: true), dcp)
        case 0xDB: rmw(addrAbsIndexed(y, write: true), dcp)
        case 0xC3: rmw(addrIndX(), dcp)
        case 0xD3: rmw(addrIndY(write: true), dcp)

        case 0xE7: rmw(addrZP(), isc)
        case 0xF7: rmw(addrZPX(), isc)
        case 0xEF: rmw(addrAbs(), isc)
        case 0xFF: rmw(addrAbsIndexed(x, write: true), isc)
        case 0xFB: rmw(addrAbsIndexed(y, write: true), isc)
        case 0xE3: rmw(addrIndX(), isc)
        case 0xF3: rmw(addrIndY(write: true), isc)

        case 0x87: write(addrZP(), a & x)
        case 0x97: write(addrZPY(), a & x)
        case 0x8F: write(addrAbs(), a & x)
        case 0x83: write(addrIndX(), a & x)

        case 0xA7: a = read(addrZP()); x = a; setZN(a)
        case 0xB7: a = read(addrZPY()); x = a; setZN(a)
        case 0xAF: a = read(addrAbs()); x = a; setZN(a)
        case 0xBF: a = read(addrAbsIndexed(y, write: false)); x = a; setZN(a)
        case 0xA3: a = read(addrIndX()); x = a; setZN(a)
        case 0xB3: a = read(addrIndY(write: false)); x = a; setZN(a)

        case 0x0B, 0x2B:   // ANC
            a &= fetch(); setZN(a); fC = fN
        case 0x4B:         // ALR
            a &= fetch(); a = lsr(a)
        case 0x6B:         // ARR
            a &= fetch()
            a = (a >> 1) | (fC ? 0x80 : 0)
            setZN(a)
            fC = (a & 0x40) != 0
            fV = ((a >> 6) ^ (a >> 5)) & 1 != 0
        case 0x8B:         // ANE / XAA (unstable; common magic constant $EE)
            a = (a | 0xEE) & x & fetch(); setZN(a)
        case 0xAB:         // LXA (unstable)
            a = (a | 0xEE) & fetch(); x = a; setZN(a)
        case 0xCB:         // AXS / SBX
            let v = fetch()
            let t = a & x
            fC = t >= v
            x = t &- v
            setZN(x)
        case 0xBB:         // LAS
            let v = read(addrAbsIndexed(y, write: false)) & s
            a = v; x = v; s = v; setZN(v)

        case 0x93:         // SHA (ind),Y
            let zp = fetch()
            let lo = read(UInt16(zp)), hi = read(UInt16(zp &+ 1))
            let base = UInt16(hi) << 8 | UInt16(lo)
            let addr = base &+ UInt16(y)
            dummyRead((base & 0xFF00) | (addr & 0x00FF))
            storeUnstable(base: base, address: addr, value: a & x)
        case 0x9F:         // SHA abs,Y
            let (base, addr) = addrAbsIndexedRaw(y)
            storeUnstable(base: base, address: addr, value: a & x)
        case 0x9C:         // SHY abs,X
            let (base, addr) = addrAbsIndexedRaw(x)
            storeUnstable(base: base, address: addr, value: y)
        case 0x9E:         // SHX abs,Y
            let (base, addr) = addrAbsIndexedRaw(y)
            storeUnstable(base: base, address: addr, value: x)
        case 0x9B:         // TAS abs,Y
            s = a & x
            let (base, addr) = addrAbsIndexedRaw(y)
            storeUnstable(base: base, address: addr, value: s)

        // MARK: JAM
        default:
            // 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2
            jammed = true
            pc &-= 1
        }
    }

    // Unofficial RMW helpers
    @inline(__always) func slo(_ v: UInt8) -> UInt8 { let r = asl(v); a |= r; setZN(a); return r }
    @inline(__always) func rla(_ v: UInt8) -> UInt8 { let r = rol(v); a &= r; setZN(a); return r }
    @inline(__always) func sre(_ v: UInt8) -> UInt8 { let r = lsr(v); a ^= r; setZN(a); return r }
    @inline(__always) func rra(_ v: UInt8) -> UInt8 { let r = ror(v); adc(r); return r }
    @inline(__always) func dcp(_ v: UInt8) -> UInt8 { let r = v &- 1; compare(a, r); return r }
    @inline(__always) func isc(_ v: UInt8) -> UInt8 { let r = v &+ 1; sbc(r); return r }

    // MARK: - Save states

    func saveState(_ w: inout StateWriter) {
        w.write(a); w.write(x); w.write(y); w.write(s); w.write(pc); w.write(p)
        w.write(cycleCount); w.write(masterClock)
        for f in [prevNMILine, needNMI, prevNeedNMI, runIRQ, prevRunIRQ, jammed,
                  needHalt, needDummyRead, dmcDMARunning, spriteDMATransfer] {
            w.write(f)
        }
        w.write(spriteDMAPage)
        w.write(openBus)
        w.write(ram)
    }

    func loadState(_ r: inout StateReader) throws {
        a = try r.readU8(); x = try r.readU8(); y = try r.readU8(); s = try r.readU8()
        pc = try r.readU16(); p = try r.readU8()
        cycleCount = try r.readU64(); masterClock = try r.readU64()
        prevNMILine = try r.readBool(); needNMI = try r.readBool()
        prevNeedNMI = try r.readBool(); runIRQ = try r.readBool(); prevRunIRQ = try r.readBool()
        jammed = try r.readBool(); needHalt = try r.readBool(); needDummyRead = try r.readBool()
        dmcDMARunning = try r.readBool(); spriteDMATransfer = try r.readBool()
        spriteDMAPage = try r.readU8()
        openBus = try r.readU8()
        try r.read(into: ram)
    }
}
