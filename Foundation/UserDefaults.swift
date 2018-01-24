// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

import CoreFoundation

private var registeredDefaults = [String: NSObject]()
private var sharedDefaults = UserDefaults()

internal func plistValueAsNSObject(_ value: Any) -> NSObject? {
    let nsValue: NSObject
    
    // Converts a value to the internal representation. Internalized values are
    // stored as NSObject derived objects in the registration dictionary.
    if let val = value as? String {
        nsValue = val._nsObject
    } else if let val = value as? URL {
        nsValue = val.path._nsObject
    } else if let val = value as? Int {
        nsValue = NSNumber(value: val)
    } else if let val = value as? Double {
        nsValue = NSNumber(value: val)
    } else if let val = value as? Bool {
        nsValue = NSNumber(value: val)
    } else if let val = value as? Data {
        nsValue = val._nsObject
    } else if let val = value as? Date {
        nsValue = val._nsObject
    } else if let val = value as? [Any] {
        var nsValues: [NSObject] = []
        for innerValue in val {
            guard let nsInnerValue = plistValueAsNSObject(innerValue) else { return nil }
            nsValues.append(nsInnerValue)
        }
        return NSArray(array: nsValues)
    } else if let val = value as? [String: Any] {
        var nsValues: [String: NSObject] = [:]
        for (key, innerValue) in val {
            guard let nsInnerValue = plistValueAsNSObject(innerValue) else { return nil }
            nsValues[key] = nsInnerValue
        }
        return NSDictionary(dictionary: nsValues)
    } else if let val = value as? NSObject {
        nsValue = val
    } else {
        return nil
    }
    
    return nsValue
}

internal func plistNSObjectAsValue(_ nsValue: NSObject) -> Any {
    let value: Any
    
    // Converts a value to the internal representation. Internalized values are
    // stored as NSObject derived objects in the registration dictionary.
    if let val = nsValue as? NSString {
        value = val._swiftObject
    } else if let val = nsValue as? NSNumber {
        value = val._swiftValueOfOptimalType
    } else if let val = nsValue as? NSData {
        value = val._swiftObject
    } else if let val = nsValue as? NSArray {
        value = val._swiftObject.map { plistNSObjectAsValue($0 as! NSObject) }
    } else if let val = nsValue as? NSDictionary {
        var values: [String: Any] = [:]
        for (currentKey, currentInnerValue) in val {
            let key: String
            
            if let swiftKey = currentKey as? String {
                key = swiftKey
            } else if let nsKey = currentKey as? NSString {
                key = nsKey._swiftObject
            } else {
                continue
            }
            
            if let nsInnerValue = currentInnerValue as? NSObject {
                values[key] = plistNSObjectAsValue(nsInnerValue)
            } else {
                values[key] = currentInnerValue
            }
        }
        value = values
    } else if let val = nsValue as? NSDate {
        value = val._swiftObject
    } else {
        value = nsValue
    }
    
    return value
}

private extension Dictionary {
    func convertingValuesToNSObjects() -> [Key: NSObject]? {
        var result: [Key: NSObject] = [:]
        
        for (key, value) in self {
            if let nsValue = plistValueAsNSObject(value) {
                result[key] = nsValue
            } else {
                return nil
            }
        }
        
        return result
    }
}

private extension Dictionary where Value == NSObject {
    mutating func merge(convertingValuesToNSObject source: [Key: Any], uniquingKeysWith block: (NSObject, NSObject) throws -> Value) rethrows -> Bool {
        if let converted = source.convertingValuesToNSObjects() {
            try self.merge(converted, uniquingKeysWith: block)
            return true
        } else {
            return false
        }
    }
    
    func convertingValuesFromPlistNSObject() -> [Key: Any] {
        var result: [Key: Any] = [:]
        for (key, value) in self {
            result[key] = plistNSObjectAsValue(value)
        }
        return result
    }
}

open class UserDefaults: NSObject {
    private let suite: String?
    
    open class var standard: UserDefaults {
        return sharedDefaults
    }
    
    open class func resetStandardUserDefaults() {
        //sharedDefaults.synchronize()
        //sharedDefaults = UserDefaults()
    }
    
    public convenience override init() {
        self.init(suiteName: nil)!
    }
    
    /// nil suite means use the default search list that +standardUserDefaults uses
    public init?(suiteName suitename: String?) {
        suite = suitename
        super.init()
        
        setVolatileDomain(UserDefaults._parsedArgumentsDomain, forName: UserDefaults.argumentDomain)
    }
    
    open func object(forKey defaultName: String) -> Any? {
        let argumentDomain = volatileDomain(forName: UserDefaults.argumentDomain)
        if let object = argumentDomain[defaultName] {
            return object
        }
        
        func getFromRegistered() -> Any? {
            return registeredDefaults[defaultName]
        }
        
        guard let anObj = CFPreferencesCopyAppValue(defaultName._cfObject, suite?._cfObject ?? kCFPreferencesCurrentApplication) else {
            return getFromRegistered()
        }
        
        //Force the returned value to an NSObject
        switch CFGetTypeID(anObj) {
        case CFStringGetTypeID():
            return unsafeBitCast(anObj, to: NSString.self)
            
        case CFNumberGetTypeID():
            return unsafeBitCast(anObj, to: NSNumber.self)
            
        case CFURLGetTypeID():
            return unsafeBitCast(anObj, to: NSURL.self)
            
        case CFArrayGetTypeID():
            return unsafeBitCast(anObj, to: NSArray.self)
            
        case CFDictionaryGetTypeID():
            return unsafeBitCast(anObj, to: NSDictionary.self)
            
        case CFDataGetTypeID():
            return unsafeBitCast(anObj, to: NSData.self)
            
        default:
            return getFromRegistered()
        }
    }

    open func set(_ value: Any?, forKey defaultName: String) {
        guard let value = value else {
            CFPreferencesSetAppValue(defaultName._cfObject, nil, suite?._cfObject ?? kCFPreferencesCurrentApplication)
            return
        }
        
        let cfType: CFTypeRef
		
		// Convert the input value to the internal representation. All values are
        // represented as CFTypeRef objects internally because we store the defaults
        // in a CFPreferences type.
        if let bType = value as? NSNumber {
            cfType = bType._cfObject
        } else if let bType = value as? NSString {
            cfType = bType._cfObject
        } else if let bType = value as? NSArray {
            cfType = bType._cfObject
        } else if let bType = value as? NSDictionary {
            cfType = bType._cfObject
        } else if let bType = value as? NSData {
            cfType = bType._cfObject
        } else if let bType = value as? NSURL {
            set(URL(reference: bType), forKey: defaultName)
            return
        } else if let bType = value as? String {
            cfType = bType._cfObject
        } else if let bType = value as? URL {
			set(bType, forKey: defaultName)
			return
        } else if let bType = value as? Int {
            var cfValue = Int64(bType)
            cfType = CFNumberCreate(nil, kCFNumberSInt64Type, &cfValue)
        } else if let bType = value as? Double {
            var cfValue = bType
            cfType = CFNumberCreate(nil, kCFNumberDoubleType, &cfValue)
        } else if let bType = value as? Data {
            cfType = bType._cfObject
        } else {
            fatalError("The type of 'value' passed to UserDefaults.set(forKey:) is not supported.")
        }
        
        CFPreferencesSetAppValue(defaultName._cfObject, cfType, suite?._cfObject ?? kCFPreferencesCurrentApplication)
    }
    open func removeObject(forKey defaultName: String) {
        CFPreferencesSetAppValue(defaultName._cfObject, nil, suite?._cfObject ?? kCFPreferencesCurrentApplication)
    }
    open func string(forKey defaultName: String) -> String? {
        guard let aVal = object(forKey: defaultName),
              let bVal = aVal as? NSString else {
            return nil
        }
        return bVal._swiftObject
    }
    open func array(forKey defaultName: String) -> [Any]? {
        guard let aVal = object(forKey: defaultName),
              let bVal = aVal as? NSArray else {
            return nil
        }
        return bVal._swiftObject
    }
    open func dictionary(forKey defaultName: String) -> [String : Any]? {
        guard let aVal = object(forKey: defaultName),
              let bVal = aVal as? NSDictionary else {
            return nil
        }
        //This got out of hand fast...
        let cVal = bVal._swiftObject
        enum convErr: Swift.Error {
            case convErr
        }
        do {
            let dVal = try cVal.map({ (key, val) -> (String, Any) in
                if let strKey = key as? NSString {
                    return (strKey._swiftObject, val)
                } else {
                    throw convErr.convErr
                }
            })
            var eVal = [String : Any]()
            
            for (key, value) in dVal {
                eVal[key] = value
            }
            
            return eVal
        } catch _ { }
        return nil
    }
    open func data(forKey defaultName: String) -> Data? {
        guard let aVal = object(forKey: defaultName),
              let bVal = aVal as? NSData else {
            return nil
        }
        return Data(referencing: bVal)
    }
    open func stringArray(forKey defaultName: String) -> [String]? {
        guard let aVal = object(forKey: defaultName),
              let bVal = aVal as? NSArray else {
            return nil
        }
        return _SwiftValue.fetch(nonOptional: bVal) as? [String]
    }
    open func integer(forKey defaultName: String) -> Int {
        guard let aVal = object(forKey: defaultName) else {
            return 0
        }
        if let bVal = aVal as? NSNumber {
            return bVal.intValue
        }
        if let bVal = aVal as? NSString {
            return bVal.integerValue
        }
        return 0
    }
    open func float(forKey defaultName: String) -> Float {
        guard let aVal = object(forKey: defaultName) else {
            return 0
        }
        if let bVal = aVal as? NSNumber {
            return bVal.floatValue
        }
        if let bVal = aVal as? NSString {
            return bVal.floatValue
        }
        return 0
    }
    open func double(forKey defaultName: String) -> Double {
        guard let aVal = object(forKey: defaultName) else {
            return 0
        }
        if let bVal = aVal as? NSNumber {
            return bVal.doubleValue
        }
        if let bVal = aVal as? NSString {
            return bVal.doubleValue
        }
        return 0
    }
    open func bool(forKey defaultName: String) -> Bool {
        guard let aVal = object(forKey: defaultName) else {
            return false
        }
        if let bVal = aVal as? NSNumber {
            return bVal.boolValue
        }
        if let bVal = aVal as? NSString {
            return bVal.boolValue
        }
        return false
    }
    open func url(forKey defaultName: String) -> URL? {
        guard let aVal = object(forKey: defaultName) else {
            return nil
        }
        
        if let bVal = aVal as? NSURL {
            return URL(reference: bVal)
        } else if let bVal = aVal as? NSString {
            let cVal = bVal.expandingTildeInPath
            
            return URL(fileURLWithPath: cVal)
        } else if let bVal = aVal as? Data {
            return NSKeyedUnarchiver.unarchiveObject(with: bVal) as? URL
        }
        return nil
    }
    
    open func set(_ value: Int, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }
    open func set(_ value: Float, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }
    open func set(_ value: Double, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }
    open func set(_ value: Bool, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }
    open func set(_ url: URL?, forKey defaultName: String) {
        if let url = url {
            //FIXME: CFURLIsFileReferenceURL is limited to OS X/iOS
            #if os(OSX) || os(iOS)
                //FIXME: no SwiftFoundation version of CFURLIsFileReferenceURL at time of writing!
                if CFURLIsFileReferenceURL(url._cfObject) {
                    let data = NSKeyedArchiver.archivedData(withRootObject: url._nsObject)
                    set(data._nsObject, forKey: defaultName)
                    return
                }
            #endif
            
            set(url.path._nsObject, forKey: defaultName)
        } else {
            set(nil, forKey: defaultName)
        }
    }
    
    open func register(defaults registrationDictionary: [String : Any]) {
        if !registeredDefaults.merge(convertingValuesToNSObject: registrationDictionary, uniquingKeysWith: { $1 }) {
            fatalError("The type of 'value' passed to UserDefaults.register(defaults:) is not supported.")
        }
    }

    open func addSuite(named suiteName: String) {
        CFPreferencesAddSuitePreferencesToApp(kCFPreferencesCurrentApplication, suiteName._cfObject)
    }
    open func removeSuite(named suiteName: String) {
        CFPreferencesRemoveSuitePreferencesFromApp(kCFPreferencesCurrentApplication, suiteName._cfObject)
    }
    
    open func dictionaryRepresentation() -> [String: Any] {
        return _dictionaryRepresentation(searchingOutsideOfSuite: true)
    }
    
    private func _dictionaryRepresentation(searchingOutsideOfSuite: Bool) -> [String: Any] {
        let registeredDefaultsIfAllowed = searchingOutsideOfSuite ? registeredDefaults : [:]
        
        guard let aPref = CFPreferencesCopyMultiple(nil, kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
            let bPref = (aPref._swiftObject) as? [NSString: Any] else {
                return registeredDefaultsIfAllowed
        }
        var allDefaults = registeredDefaultsIfAllowed
        
        for (key, value) in bPref {
            if let value = plistValueAsNSObject(value) {
                allDefaults[key._swiftObject] = value
            }
        }
        
        return allDefaults
    }
    
    private static let _parsedArgumentsDomain: [String: NSObject] = UserDefaults._parseArguments(ProcessInfo.processInfo.arguments).convertingValuesToNSObjects() ?? [:]
    
    private var _volatileDomains: [String: [String: NSObject]] = [:]
    private let _volatileDomainsLock = NSLock()
    
    open var volatileDomainNames: [String] {
        _volatileDomainsLock.lock()
        let names = Array(_volatileDomains.keys)
        _volatileDomainsLock.unlock()
        
        return names
    }
    
    open func volatileDomain(forName domainName: String) -> [String : Any] {
        _volatileDomainsLock.lock()
        let domain = _volatileDomains[domainName]
        _volatileDomainsLock.unlock()
        
        return domain?.convertingValuesFromPlistNSObject() ?? [:]
    }
    
    open func setVolatileDomain(_ domain: [String : Any], forName domainName: String) {
        _volatileDomainsLock.lock()
        var convertedDomain: [String: NSObject] = _volatileDomains[domainName] ?? [:]
        if !convertedDomain.merge(convertingValuesToNSObject: domain, uniquingKeysWith: { $1 }) {
            fatalError("The type of 'value' passed to UserDefaults.setVolatileDomain(_:forName:) is not supported.")
        }
        _volatileDomains[domainName] = convertedDomain
        _volatileDomainsLock.unlock()
    }
    
    open func removeVolatileDomain(forName domainName: String) {
        _volatileDomainsLock.lock()
        _volatileDomains.removeValue(forKey: domainName)
        _volatileDomainsLock.unlock()
    }
    
    open func persistentDomain(forName domainName: String) -> [String : Any]? {
        return UserDefaults(suiteName: domainName)?._dictionaryRepresentation(searchingOutsideOfSuite: false)
    }
    
    open func setPersistentDomain(_ domain: [String : Any], forName domainName: String) {
        if let defaults = UserDefaults(suiteName: domainName) {
            for key in defaults._dictionaryRepresentation(searchingOutsideOfSuite: false).keys {
                defaults.removeObject(forKey: key)
            }
            
            for (key, value) in domain {
                defaults.set(value, forKey: key)
            }
        }
        
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    
    open func removePersistentDomain(forName domainName: String) {
        if let defaults = UserDefaults(suiteName: domainName) {
            for key in defaults._dictionaryRepresentation(searchingOutsideOfSuite: false).keys {
                defaults.removeObject(forKey: key)
            }
            
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
        }
    }
    
    open func synchronize() -> Bool {
        return CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
    
    open func objectIsForced(forKey key: String) -> Bool {
        // If you're using this version of Foundation, there is nothing in particular that can force a key.
        // So:
        return false
    }
    
    open func objectIsForced(forKey key: String, inDomain domain: String) -> Bool {
        // If you're using this version of Foundation, there is nothing in particular that can force a key.
        // So:
        return false
    }
}

extension UserDefaults {
    public static let didChangeNotification = NSNotification.Name(rawValue: "NSUserDefaultsDidChangeNotification")
    public static let globalDomain: String = "NSGlobalDomain"
    public static let argumentDomain: String = "NSArgumentDomain"
    public static let registrationDomain: String = "NSRegistrationDomain"
}
