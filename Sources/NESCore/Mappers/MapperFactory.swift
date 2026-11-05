/// Creates the board implementation for a cartridge.
public enum MapperFactory {
    /// iNES mapper numbers this core implements.
    public static let supportedMappers: [Int: String] = [
        0: "NROM", 1: "MMC1", 2: "UxROM", 3: "CNROM", 4: "MMC3/MMC6", 5: "MMC5",
        7: "AxROM", 9: "MMC2", 10: "MMC4", 11: "Color Dreams", 13: "CPROM",
        21: "VRC4a/c", 22: "VRC2a", 23: "VRC2b/VRC4e", 24: "VRC6a", 25: "VRC2c/VRC4b/d", 26: "VRC6b",
        34: "BNROM/NINA-001", 66: "GxROM", 69: "Sunsoft FME-7/5B", 71: "Camerica",
        75: "VRC1", 79: "NINA-003/006", 87: "Jaleco J87", 94: "UN1ROM", 113: "NINA-006 (113)",
        118: "TxSROM", 119: "TQROM", 140: "Jaleco JF-11", 180: "UNROM (180)", 185: "CNROM (185)",
        206: "Namco 108", 232: "Camerica Quattro",
    ]

    public static func isSupported(_ mapper: Int) -> Bool { supportedMappers[mapper] != nil }

    public static func make(for cartridge: Cartridge) throws -> Mapper {
        let type: Mapper.Type
        switch cartridge.mapperID {
        case 0: type = NROM.self
        case 1: type = MMC1.self
        case 2, 94, 180: type = UxROM.self
        case 3, 185: type = CNROM.self
        case 4: type = MMC3.self
        case 5: type = MMC5.self
        case 7: type = AxROM.self
        case 9, 10: type = MMC2.self
        case 11: type = ColorDreams.self
        case 13: type = CPROM.self
        case 21, 22, 23, 25: type = VRC24.self
        case 24, 26: type = VRC6.self
        case 34: type = BNROM.self
        case 66: type = GxROM.self
        case 69: type = FME7.self
        case 71: type = Camerica.self
        case 75: type = VRC1.self
        case 79, 113: type = NINA03.self
        case 87: type = Mapper87.self
        case 118: type = TxSROM.self
        case 119: type = TQROM.self
        case 140: type = Mapper140.self
        case 206: type = Namco108.self
        case 232: type = Quattro.self
        default: throw CartridgeError.unsupportedMapper(cartridge.mapperID)
        }
        return type.init(cartridge: cartridge)
    }
}
