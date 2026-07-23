#!/usr/bin/env swift

// Copyright (c) 2026 Walter Horbert
// Licensed under the MIT License. See LICENSE.

import Foundation
import CryptoKit
import UserNotifications

#if canImport(Darwin)
import Darwin
#endif

// UDP Map Toy: a generic WSJT-X/JTDX heard-map server for macOS.
// - Receives UDP datagrams on a BSD socket bound to INADDR_ANY
// - Parses WSJT-X style packets
// - Extracts calls + Maidenhead locators from decode text
// - Writes a JSON feed
// - Serves a local Leaflet map over HTTP
//
// Build:
//   swiftc -o udp-map-toy udp-map-toy.swift
// Run (--my-grid is required; ADIF identity fields are optional):
//   ./udp-map-toy --my-grid FN31pr
//   ./udp-map-toy --my-grid FN31pr --operator W1AW --my-country USA
// Open:
//   http://127.0.0.1:8080/

func printUsageAndExit() -> Never {
    let usage = """
    UDP Map Toy - WSJT-X/JTDX heard-map server for macOS

    Required:
      --my-grid GRID              Your Maidenhead grid square (e.g. FN31pr)

    Optional:
      --operator CALLSIGN         Callsign to write into ADIF OPERATOR (default: N0CALL)
      --my-name NAME              Optional ADIF MY_NAME value
      --my-city CITY              Optional ADIF MY_CITY value
      --my-state STATE            Optional ADIF MY_STATE value
      --my-county COUNTY          Optional ADIF MY_CNTY value
      --my-dxcc DXCC              Optional ADIF MY_DXCC value
      --my-country COUNTRY        Optional ADIF MY_COUNTRY value
      --udp-port PORT             UDP port to listen on (default: 2237)
      --http-port PORT            HTTP port to serve the map on (default: 8080)
      --html PATH                 Path to write the heard-map HTML (default: ~/udp-map-toy.html)
      --json PATH                 Path to write the spots JSON feed (default: ~/spots.json)
      --adif PATH                 Path to write the ADIF log (default: ~/udp-map-toy-YYYY-MM-DD.adi)
      --program-id NAME           ADIF PROGRAMID string (default: "UDP Map Toy")
      --notify-distance MILES     Minimum distance to trigger a DX notification (default: 1000)
      --hamqth-user USER          HamQTH username for callsign lookups (or set HAMQTH_USER env var)
      --hamqth-password PASS      HamQTH password for callsign lookups (or set HAMQTH_PASSWORD env var)
      --quiet                     Suppress verbose console logging
      --help                      Show this help message and exit
    """
    print(usage)
    exit(0)
}

struct Config {
    let udpPort: UInt16
    let httpPort: UInt16
    let htmlPath: URL
    let jsonPath: URL
    let adifPath: URL
    let verbose: Bool

    let programID: String
    let programVersion = "1.0.0"
    let operatorCall: String
    let myGrid: String
    let myName: String
    let myCity: String
    let myState: String
    let myCounty: String
    let myDXCC: String
    let myCountry: String
    let notifyDistanceMiles: Double
    let hamQTHUser: String?
    let hamQTHPassword: String?

    init() {
        var udp: UInt16 = 2237
        var http: UInt16 = 8080
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var html = home.appendingPathComponent("udp-map-toy.html")
        var json = home.appendingPathComponent("spots.json")
        var adif = home.appendingPathComponent("udp-map-toy-\(stamp).adi")
        var verbose = true
        var programID = "UDP Map Toy"

        var operatorCall = "N0CALL"
        var myGrid: String?
        var myName = ""
        var myCity = ""
        var myState = ""
        var myCounty = ""
        var myDXCC = ""
        var myCountry = ""
        var notifyDistanceMiles = 1000.0
        var hamQTHUser: String?
        var hamQTHPassword: String?

        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--help", "-h":
                printUsageAndExit()
            case "--udp-port":
                if i + 1 < args.count, let v = UInt16(args[i + 1]) { udp = v; i += 1 }
            case "--http-port":
                if i + 1 < args.count, let v = UInt16(args[i + 1]) { http = v; i += 1 }
            case "--html":
                if i + 1 < args.count { html = URL(fileURLWithPath: args[i + 1]); i += 1 }
            case "--json":
                if i + 1 < args.count { json = URL(fileURLWithPath: args[i + 1]); i += 1 }
            case "--adif":
                if i + 1 < args.count { adif = URL(fileURLWithPath: args[i + 1]); i += 1 }
            case "--program-id":
                if i + 1 < args.count { programID = args[i + 1]; i += 1 }
            case "--operator":
                if i + 1 < args.count { operatorCall = args[i + 1]; i += 1 }
            case "--my-grid":
                if i + 1 < args.count { myGrid = args[i + 1]; i += 1 }
            case "--my-name":
                if i + 1 < args.count { myName = args[i + 1]; i += 1 }
            case "--my-city":
                if i + 1 < args.count { myCity = args[i + 1]; i += 1 }
            case "--my-state":
                if i + 1 < args.count { myState = args[i + 1]; i += 1 }
            case "--my-county":
                if i + 1 < args.count { myCounty = args[i + 1]; i += 1 }
            case "--my-dxcc":
                if i + 1 < args.count { myDXCC = args[i + 1]; i += 1 }
            case "--my-country":
                if i + 1 < args.count { myCountry = args[i + 1]; i += 1 }
            case "--notify-distance":
                if i + 1 < args.count, let v = Double(args[i + 1]) { notifyDistanceMiles = v; i += 1 }
            case "--hamqth-user":
                if i + 1 < args.count { hamQTHUser = args[i + 1]; i += 1 }
            case "--hamqth-password":
                if i + 1 < args.count { hamQTHPassword = args[i + 1]; i += 1 }
            case "--quiet":
                verbose = false
            default:
                break
            }
            i += 1
        }

        var missing = [String]()
        if myGrid == nil { missing.append("--my-grid") }
        if !missing.isEmpty {
            fputs("Missing required argument(s): \(missing.joined(separator: ", "))\n\n", stderr)
            printUsageAndExit()
        }

        self.udpPort = udp
        self.httpPort = http
        self.htmlPath = html
        self.jsonPath = json
        self.adifPath = adif
        self.verbose = verbose
        self.programID = programID
        self.operatorCall = operatorCall
        self.myGrid = myGrid!
        self.myName = myName
        self.myCity = myCity
        self.myState = myState
        self.myCounty = myCounty
        self.myDXCC = myDXCC
        self.myCountry = myCountry
        self.notifyDistanceMiles = notifyDistanceMiles
        self.hamQTHUser = hamQTHUser
        self.hamQTHPassword = hamQTHPassword
    }
}

struct HeardSpot: Codable, Hashable {
    let id: String
    let call: String
    let grid: String
    let lat: Double
    let lon: Double
    let mode: String
    let freq: String
    let report: String
    let snr: Int
    let timestamp: String
    let comment: String
    let band: String
    let distanceMiles: Double
    let isDX: Bool
    let displayLocation: String?
    let lookupCity: String?
    let lookupState: String?
    let lookupCountry: String?
    let lookupGrid: String?
    let lookupSource: String?
}

struct SpotFeed: Codable {
    let spots: [HeardSpot]
}

struct LookupResolver {
    struct GeographicContribution {
        let city: String?
        let state: String?
        let country: String?
        let grid: String?
        let source: String?
    }

    static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func isUSLike(_ country: String?) -> Bool {
        guard let value = cleaned(country)?.uppercased() else { return false }
        return value == "UNITED STATES" || value == "USA" || value == "UNITED STATES OF AMERICA"
    }

    static func isLikelyStateAbbreviation(_ value: String?) -> Bool {
        guard let text = cleaned(value)?.uppercased() else { return false }
        guard text.count == 2 else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    static func preferredLocationPart(_ lhs: String?, _ rhs: String?) -> String? {
        let left = cleaned(lhs)
        let right = cleaned(rhs)
        switch (left, right) {
        case let (l?, r?):
            if l.caseInsensitiveCompare(r) == .orderedSame { return l }
            return l.count >= r.count ? l : r
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        default:
            return nil
        }
    }

    static func preferredState(_ lhs: String?, _ rhs: String?) -> String? {
        let left = cleaned(lhs)
        let right = cleaned(rhs)
        switch (left, right) {
        case let (l?, r?):
            if l.caseInsensitiveCompare(r) == .orderedSame { return l }
            let leftAbbrev = isLikelyStateAbbreviation(l)
            let rightAbbrev = isLikelyStateAbbreviation(r)
            if leftAbbrev != rightAbbrev {
                return leftAbbrev ? r : l
            }
            return l.count >= r.count ? l : r
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        default:
            return nil
        }
    }

    static func preferredGrid(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let grid = cleaned(candidate)?.uppercased(), [4, 6, 8, 10].contains(grid.count) else { continue }
            return grid
        }
        return nil
    }


    static func gridPrefix(_ grid: String?, length: Int = 4) -> String? {
        guard let value = preferredGrid(grid), value.count >= length else { return nil }
        return String(value.prefix(length)).uppercased()
    }

    static func isLookupGridConsistent(decodedGrid: String, lookupGrid: String?) -> Bool {
        guard let decodedPrefix = gridPrefix(decodedGrid), let lookupPrefix = gridPrefix(lookupGrid) else {
            return false
        }
        return decodedPrefix == lookupPrefix
    }

    static func contribution(decodedGrid: String, lookupCity: String?, lookupState: String?, lookupCountry: String?, lookupGrid: String?, lookupSource: String?) -> GeographicContribution? {
        let normalizedGrid = preferredGrid(lookupGrid)
        if let normalizedGrid, isLookupGridConsistent(decodedGrid: decodedGrid, lookupGrid: normalizedGrid) {
            return GeographicContribution(
                city: cleaned(lookupCity),
                state: cleaned(lookupState),
                country: cleaned(lookupCountry),
                grid: normalizedGrid,
                source: cleaned(lookupSource)
            )
        }
        return nil
    }


    static func bestGrid(for spot: HeardSpot) -> String {
        preferredGrid(spot.lookupGrid, spot.grid) ?? spot.grid.uppercased()
    }


    static func updatedDistance(for spot: HeardSpot, myGrid: String) -> (distanceMiles: Double, isDX: Bool) {
        let bestGrid = self.bestGrid(for: spot)
        guard let remote = Maidenhead.toCoordinate(bestGrid) else {
            return (spot.distanceMiles, spot.isDX)
        }
        let myCoord = Maidenhead.toCoordinate(myGrid) ?? (lat: 0.0, lon: 0.0)
        let distance = DistanceHelper.haversineMiles(
            lat1: myCoord.lat,
            lon1: myCoord.lon,
            lat2: remote.lat,
            lon2: remote.lon
        )
        return (distance, distance >= 1000)
    }

    static func combinedSource(_ lhs: String?, _ rhs: String?) -> String? {
        var seen = Set<String>()
        var ordered: [String] = []
        for part in [lhs, rhs] {
            guard let value = cleaned(part) else { continue }
            for token in value.split(separator: "+").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }) where !token.isEmpty {
                let key = token.uppercased()
                if seen.insert(key).inserted {
                    ordered.append(token)
                }
            }
        }
        return ordered.isEmpty ? nil : ordered.joined(separator: "+")
    }

    static func displayLocation(city: String?, state: String?, country: String?) -> String? {
        let city = cleaned(city)
        let state = cleaned(state)
        let country = cleaned(country)

        if let city, let state, isUSLike(country) {
            return "\(city), \(state)"
        }
        if let city, let country {
            return "\(city), \(country)"
        }
        if let city, let state {
            return "\(city), \(state)"
        }
        if let city { return city }
        if let state, isUSLike(country) { return state }
        if let country { return country }
        return nil
    }

    static func applying(contribution: GeographicContribution?, to spot: HeardSpot) -> HeardSpot {
        let city = preferredLocationPart(spot.lookupCity, contribution?.city)
        let state = preferredState(spot.lookupState, contribution?.state)
        let country = preferredLocationPart(spot.lookupCountry, contribution?.country)
        let grid = preferredGrid(contribution?.grid, spot.lookupGrid, spot.grid)
        let source = combinedSource(spot.lookupSource, contribution?.source)
        return HeardSpot(
            id: spot.id,
            call: spot.call,
            grid: spot.grid,
            lat: spot.lat,
            lon: spot.lon,
            mode: spot.mode,
            freq: spot.freq,
            report: spot.report,
            snr: spot.snr,
            timestamp: spot.timestamp,
            comment: spot.comment,
            band: spot.band,
            distanceMiles: spot.distanceMiles,
            isDX: spot.isDX,
            displayLocation: displayLocation(city: city, state: state, country: country),
            lookupCity: city,
            lookupState: state,
            lookupCountry: country,
            lookupGrid: grid,
            lookupSource: source
        )
    }
}

struct HamQTHLookup {
    let callsign: String
    let city: String?
    let state: String?
    let country: String?
    let grid: String?

    var preferredGrid: String? {
        LookupResolver.preferredGrid(grid)
    }
}

struct HamDBLookup {
    let callsign: String
    let city: String?
    let state: String?
    let country: String?
    let grid: String?
    let lat: Double?
    let lon: Double?

    var preferredGrid: String? {
        if let grid = LookupResolver.preferredGrid(grid) {
            return grid
        }
        if let lat, let lon {
            return Maidenhead.fromCoordinate(lat: lat, lon: lon, precision: 6)?.uppercased()
        }
        return nil
    }
}

private enum LookupCacheEntry<Value> {
    case success(Value)
    case negative
}

final class HamDBClient {
    private let queue = DispatchQueue(label: "hamdb.client")
    private let appName: String
    private let session: URLSession
    private let minimumLookupInterval: TimeInterval
    private var cache = [String: LookupCacheEntry<HamDBLookup>]()
    private var inFlight = Set<String>()
    private var nextAllowedRequestTime = Date.distantPast

    init(appName: String = "udp-map-toy", minimumLookupInterval: TimeInterval = 1.0) {
        self.appName = appName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appName
        self.minimumLookupInterval = max(0, minimumLookupInterval)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    func enrich(_ spot: HeardSpot, completion: @escaping (HeardSpot?) -> Void) {
        let key = normalized(spot.call)
        queue.async {
            if let cached = self.cache[key] {
                switch cached {
                case .success(let lookup):
                    completion(self.enriched(spot: spot, lookup: lookup))
                case .negative:
                    completion(nil)
                }
                return
            }
            if self.inFlight.contains(key) {
                completion(nil)
                return
            }
            self.inFlight.insert(key)
            self.enqueueLookup(callsign: key) { lookup, isNegative in
                self.queue.async {
                    self.inFlight.remove(key)
                    if let lookup {
                        self.cache[key] = .success(lookup)
                    } else if isNegative {
                        self.cache[key] = .negative
                    }
                    completion(lookup.flatMap { self.enriched(spot: spot, lookup: $0) })
                }
            }
        }
    }

    private func enriched(spot: HeardSpot, lookup: HamDBLookup) -> HeardSpot? {
        let finalGrid = lookup.preferredGrid ?? spot.grid
        guard Maidenhead.toCoordinate(finalGrid) != nil else { return nil }
        let contribution = LookupResolver.contribution(
            decodedGrid: spot.grid,
            lookupCity: lookup.city,
            lookupState: lookup.state,
            lookupCountry: lookup.country,
            lookupGrid: finalGrid,
            lookupSource: lookup.grid != nil ? "HamDB" : ((lookup.lat != nil && lookup.lon != nil) ? "HamDB(lat/lon)" : "HamDB")
        )
        let merged = LookupResolver.applying(contribution: contribution, to: spot)
        let updated = LookupResolver.updatedDistance(for: merged, myGrid: config.myGrid)
        return HeardSpot(
            id: merged.id,
            call: merged.call,
            grid: merged.grid,
            lat: merged.lat,
            lon: merged.lon,
            mode: merged.mode,
            freq: merged.freq,
            report: merged.report,
            snr: merged.snr,
            timestamp: merged.timestamp,
            comment: merged.comment,
            band: merged.band,
            distanceMiles: updated.distanceMiles,
            isDX: updated.isDX,
            displayLocation: merged.displayLocation,
            lookupCity: merged.lookupCity,
            lookupState: merged.lookupState,
            lookupCountry: merged.lookupCountry,
            lookupGrid: merged.lookupGrid,
            lookupSource: merged.lookupSource
        )
    }

    private func enqueueLookup(callsign: String, completion: @escaping (HamDBLookup?, Bool) -> Void) {
        queue.async {
            let now = Date()
            let fireAt = max(now, self.nextAllowedRequestTime)
            self.nextAllowedRequestTime = fireAt.addingTimeInterval(self.minimumLookupInterval)
            let delay = fireAt.timeIntervalSince(now)
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.lookup(callsign: callsign, completion: completion)
            }
        }
    }

    private func lookup(callsign: String, completion: @escaping (HamDBLookup?, Bool) -> Void) {
        let encoded = callsign.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? callsign
        guard let url = URL(string: "https://api.hamdb.org/\(encoded)/json/\(appName)") else {
            completion(nil, false)
            return
        }

        session.dataTask(with: url) { data, _, _ in
            guard let data else {
                completion(nil, false)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hamdb = json["hamdb"] as? [String: Any] else {
                completion(nil, false)
                return
            }

            if let messages = hamdb["messages"] as? [String: Any],
               let status = messages["status"] as? String,
               status.uppercased() == "NOT_FOUND" {
                completion(nil, true)
                return
            }

            guard let callsignBlock = hamdb["callsign"] as? [String: Any] else {
                completion(nil, false)
                return
            }

            if let call = callsignBlock["call"] as? String,
               call.uppercased() == "NOT_FOUND" {
                completion(nil, true)
                return
            }

            let lookup = HamDBLookup(
                callsign: callsign,
                city: Self.string(callsignBlock["city"]),
                state: Self.string(callsignBlock["state"]),
                country: Self.string(callsignBlock["country"]),
                grid: Self.string(callsignBlock["grid"]),
                lat: Self.double(callsignBlock["lat"]),
                lon: Self.double(callsignBlock["lon"])
            )
            completion(lookup, false)
        }.resume()
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func normalized(_ callsign: String) -> String {
        callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class HamQTHClient {
    private let queue = DispatchQueue(label: "hamqth.client")
    private let username: String
    private let password: String
    private let programName: String
    private let session: URLSession
    private let minimumLookupInterval: TimeInterval
    private var sessionID: String?
    private var sessionExpiry: Date?
    private var cache = [String: LookupCacheEntry<HamQTHLookup>]()
    private var inFlight = Set<String>()
    private var nextAllowedLookupTime = Date.distantPast
    private var nextAllowedSessionRefreshTime = Date.distantPast

    init?(username: String?, password: String?, programName: String, minimumLookupInterval: TimeInterval = 1.0) {
        guard let username = username?.trimmingCharacters(in: .whitespacesAndNewlines),
              let password = password?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty,
              !password.isEmpty else {
            return nil
        }
        self.username = username
        self.password = password
        self.programName = programName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? programName
        self.minimumLookupInterval = max(0, minimumLookupInterval)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    func enrich(_ spot: HeardSpot, completion: @escaping (HeardSpot?) -> Void) {
        let key = normalized(spot.call)
        queue.async {
            if let cached = self.cache[key] {
                switch cached {
                case .success(let lookup):
                    completion(self.enriched(spot: spot, lookup: lookup))
                case .negative:
                    completion(nil)
                }
                return
            }
            if self.inFlight.contains(key) {
                completion(nil)
                return
            }
            self.inFlight.insert(key)
            self.enqueueLookup(callsign: key) { lookup, isNegative in
                self.queue.async {
                    self.inFlight.remove(key)
                    if let lookup {
                        self.cache[key] = .success(lookup)
                    } else if isNegative {
                        self.cache[key] = .negative
                    }
                    completion(lookup.flatMap { self.enriched(spot: spot, lookup: $0) })
                }
            }
        }
    }

    private func enriched(spot: HeardSpot, lookup: HamQTHLookup) -> HeardSpot? {
        let finalGrid = lookup.preferredGrid ?? spot.grid
        guard Maidenhead.toCoordinate(finalGrid) != nil else { return nil }
        let contribution = LookupResolver.contribution(
            decodedGrid: spot.grid,
            lookupCity: lookup.city,
            lookupState: lookup.state,
            lookupCountry: lookup.country,
            lookupGrid: finalGrid,
            lookupSource: "HamQTH"
        )
        let merged = LookupResolver.applying(contribution: contribution, to: spot)
        let updated = LookupResolver.updatedDistance(for: merged, myGrid: config.myGrid)
        return HeardSpot(
            id: merged.id,
            call: merged.call,
            grid: merged.grid,
            lat: merged.lat,
            lon: merged.lon,
            mode: merged.mode,
            freq: merged.freq,
            report: merged.report,
            snr: merged.snr,
            timestamp: merged.timestamp,
            comment: merged.comment,
            band: merged.band,
            distanceMiles: updated.distanceMiles,
            isDX: updated.isDX,
            displayLocation: merged.displayLocation,
            lookupCity: merged.lookupCity,
            lookupState: merged.lookupState,
            lookupCountry: merged.lookupCountry,
            lookupGrid: merged.lookupGrid,
            lookupSource: merged.lookupSource
        )
    }

    private func enqueueLookup(callsign: String, completion: @escaping (HamQTHLookup?, Bool) -> Void) {
        queue.async {
            let now = Date()
            let fireAt = max(now, self.nextAllowedLookupTime)
            self.nextAllowedLookupTime = fireAt.addingTimeInterval(self.minimumLookupInterval)
            let delay = fireAt.timeIntervalSince(now)
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.lookup(callsign: callsign, completion: completion)
            }
        }
    }

    private func lookup(callsign: String, completion: @escaping (HamQTHLookup?, Bool) -> Void) {
        withSessionID(forceRefresh: false) { sessionID in
            guard let sessionID else {
                completion(nil, false)
                return
            }
            self.performLookup(callsign: callsign, sessionID: sessionID) { lookup, retry, isNegative in
                guard retry == false else {
                    self.withSessionID(forceRefresh: true) { refreshed in
                        guard let refreshed else {
                            completion(lookup, isNegative)
                            return
                        }
                        self.performLookup(callsign: callsign, sessionID: refreshed) { retryLookup, _, retryNegative in
                            completion(retryLookup, retryNegative)
                        }
                    }
                    return
                }
                completion(lookup, isNegative)
            }
        }
    }

    private func withSessionID(forceRefresh: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            if !forceRefresh, let sessionID = self.sessionID, let expiry = self.sessionExpiry, expiry > Date() {
                completion(sessionID)
                return
            }

            let now = Date()
            let fireAt = max(now, self.nextAllowedSessionRefreshTime)
            self.nextAllowedSessionRefreshTime = fireAt.addingTimeInterval(self.minimumLookupInterval)
            let delay = fireAt.timeIntervalSince(now)

            self.queue.asyncAfter(deadline: .now() + delay) {
                let user = self.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self.username
                let pass = self.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self.password
                guard let url = URL(string: "https://www.hamqth.com/xml.php?u=\(user)&p=\(pass)") else {
                    completion(nil)
                    return
                }

                self.session.dataTask(with: url) { data, _, _ in
                    guard let data, let xml = String(data: data, encoding: .utf8) else {
                        completion(nil)
                        return
                    }
                    if let sessionID = Self.firstTag("session_id", in: xml) ?? Self.firstTag("sessionid", in: xml) {
                        self.queue.async {
                            self.sessionID = sessionID
                            self.sessionExpiry = Date().addingTimeInterval(55 * 60)
                        }
                        completion(sessionID)
                        return
                    }
                    completion(nil)
                }.resume()
            }
        }
    }

    private func performLookup(callsign: String, sessionID: String, completion: @escaping (HamQTHLookup?, Bool, Bool) -> Void) {
        let call = callsign.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callsign
        guard let url = URL(string: "https://www.hamqth.com/xml.php?id=\(sessionID)&callsign=\(call)&prg=\(programName)") else {
            completion(nil, false, false)
            return
        }
        session.dataTask(with: url) { data, _, _ in
            guard let data, let xml = String(data: data, encoding: .utf8) else {
                completion(nil, false, false)
                return
            }
            let errorText = Self.firstTag("error", in: xml)?.uppercased()
            if let errorText, errorText.contains("SESSION") {
                completion(nil, true, false)
                return
            }
            if let errorText, errorText.contains("NOT FOUND") {
                completion(nil, false, true)
                return
            }
            let lookup = HamQTHLookup(
                callsign: callsign,
                city: Self.firstTag("adr_city", in: xml) ?? Self.firstTag("city", in: xml),
                state: Self.firstTag("us_state", in: xml) ?? Self.firstTag("district", in: xml) ?? Self.firstTag("oblast", in: xml),
                country: Self.firstTag("country", in: xml),
                grid: Self.firstTag("grid", in: xml) ?? Self.firstTag("locator", in: xml)
            )
            completion(lookup, false, false)
        }.resume()
    }

    private static func firstTag(_ tag: String, in xml: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = xml as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: xml, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        let value = ns.substring(with: match.range(at: 1))
        return decodeHTML(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTML(_ value: String) -> String {
    return value
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&apos;", with: "'")
}

    private func normalized(_ callsign: String) -> String {
        callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ADIFWriter {
    private let queue = DispatchQueue(label: "adif.writer")
    private let url: URL
    private let config: Config
    private var seen = Set<String>()

    init(url: URL, config: Config) {
        self.url = url
        self.config = config
        ensureHeader()
    }

    func append(spot: HeardSpot) {
        queue.async {
            guard !self.seen.contains(spot.id) else { return }
            self.seen.insert(spot.id)
            let record = self.makeRecord(spot: spot)
            do {
                let handle = try FileHandle(forWritingTo: self.url)
                defer {
                    do { try handle.close() }
                    catch { fputs("ADIF close failed at \(self.url.path): \(error)\n", stderr) }
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(record.utf8))
            } catch {
                fputs("ADIF append failed at \(self.url.path): \(error)\n", stderr)
            }
        }
    }

    private func ensureHeader() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let header = """
#+++++++++++++++++++++++++++++++++++++
# \(config.programID) V \(config.programVersion)
#+++++++++++++++++++++++++++++++++++++

<ADIF_VER:5>3.1.4<PROGRAMID:\(config.programID.count)>\(config.programID)<PROGRAMVERSION:\(config.programVersion.count)>\(config.programVersion)<EOH>
"""
        do {
            try Data(header.utf8).write(to: url, options: .atomic)
        } catch {
            fputs("ADIF header write failed at \(url.path): \(error)\n", stderr)
        }
    }

    private func adifField(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "<\(name):\(value.count)>\(value)"
    }

    private func makeRecord(spot: HeardSpot) -> String {
        let dt = isoToDateTime(spot.timestamp)
        let lat = formatLatitude(spot.lat)
        let lon = formatLongitude(spot.lon)
        return [
            adifField("CALL", spot.call),
            adifField("QSO_DATE", dt.date),
            adifField("TIME_ON", dt.time),
            adifField("BAND", spot.band),
            adifField("FREQ", spot.freq),
            adifField("MODE", spot.mode),
            adifField("OPERATOR", config.operatorCall),
            adifField("GRIDSQUARE", spot.grid),
            adifField("LAT", lat),
            adifField("LON", lon),
            adifField("QSL_SENT", "N"),
            adifField("QSL_RCVD", "N"),
            adifField("MY_GRIDSQUARE", config.myGrid),
            adifField("MY_NAME", config.myName),
            adifField("MY_CITY", config.myCity),
            adifField("MY_STATE", config.myState),
            adifField("MY_CNTY", config.myCounty),
            adifField("MY_DXCC", config.myDXCC),
            adifField("MY_COUNTRY", config.myCountry),
            adifField("RST_RCVD", spot.report),
            adifField("APP_SDRCONTROL_HEARD_SNR", String(spot.snr)),
            adifField("COMMENT", spot.comment),
            "<EOR>\n"
        ].joined()
    }

    private func isoToDateTime(_ iso: String) -> (date: String, time: String) {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) {
            let df = DateFormatter()
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyyMMdd"
            let tf = DateFormatter()
            tf.timeZone = TimeZone(secondsFromGMT: 0)
            tf.dateFormat = "HHmmss"
            return (df.string(from: d), tf.string(from: d))
        }
        return ("19700101", "000000")
    }

    private func formatLatitude(_ lat: Double) -> String {
        let hemi = lat >= 0 ? "N" : "S"
        let absVal = abs(lat)
        let deg = Int(absVal)
        let min = (absVal - Double(deg)) * 60.0
        return String(format: "%@%03d %06.3f", hemi, deg, min)
    }

    private func formatLongitude(_ lon: Double) -> String {
        let hemi = lon >= 0 ? "E" : "W"
        let absVal = abs(lon)
        let deg = Int(absVal)
        let min = (absVal - Double(deg)) * 60.0
        return String(format: "%@%03d %06.3f", hemi, deg, min)
    }
}

final class SpotStore {
    private let queue = DispatchQueue(label: "spot.store")
    private var spots: [HeardSpot] = []
    private var indexByKey: [String: Int] = [:]
    private var indexByID: [String: Int] = [:]
    private let jsonURL: URL
    private let maxSpots = 5000

    init(jsonURL: URL) {
        self.jsonURL = jsonURL
        writeJSON()
    }

    func add(_ spot: HeardSpot) {
        queue.async {
            if let existingIndex = self.indexByID[spot.id] {
                let merged = self.merge(existing: self.spots[existingIndex], incoming: spot)
                self.spots.remove(at: existingIndex)
                self.spots.insert(merged, at: 0)
            } else {
                let key = self.logicalKey(for: spot)
                if let existingIndex = self.indexByKey[key] {
                    let merged = self.merge(existing: self.spots[existingIndex], incoming: spot)
                    self.spots.remove(at: existingIndex)
                    self.spots.insert(merged, at: 0)
                } else {
                    self.spots.insert(spot, at: 0)
                }
            }

            if self.spots.count > self.maxSpots {
                self.spots = Array(self.spots.prefix(self.maxSpots))
            }

            self.rebuildIndex()
            self.writeJSON()
        }
    }

    func replace(_ spot: HeardSpot) {
        queue.async {
            guard let idx = self.indexByID[spot.id] else { return }
            self.spots[idx] = spot
            let replacementKey = self.logicalKey(for: spot)
            if let otherIdx = self.indexByKey[replacementKey], otherIdx != idx {
                let merged = self.merge(existing: self.spots[otherIdx], incoming: self.spots[idx])
                let low = min(idx, otherIdx)
                let high = max(idx, otherIdx)
                self.spots.remove(at: high)
                self.spots.remove(at: low)
                self.spots.insert(merged, at: 0)
            }
            self.rebuildIndex()
            self.writeJSON()
        }
    }

    private func logicalKey(for spot: HeardSpot) -> String {
        LookupResolver.bestGrid(for: spot)
    }

    private func merge(existing: HeardSpot, incoming: HeardSpot) -> HeardSpot {
        let base = HeardSpot(
            id: incoming.id,
            call: incoming.call,
            grid: incoming.grid,
            lat: incoming.lat,
            lon: incoming.lon,
            mode: incoming.mode,
            freq: incoming.freq,
            report: incoming.report,
            snr: incoming.snr,
            timestamp: incoming.timestamp,
            comment: incoming.comment,
            band: incoming.band,
            distanceMiles: incoming.distanceMiles,
            isDX: incoming.isDX || existing.isDX,
            displayLocation: nil,
            lookupCity: existing.lookupCity,
            lookupState: existing.lookupState,
            lookupCountry: existing.lookupCountry,
            lookupGrid: existing.lookupGrid,
            lookupSource: existing.lookupSource
        )
        let contribution = LookupResolver.contribution(
            decodedGrid: incoming.grid,
            lookupCity: incoming.lookupCity,
            lookupState: incoming.lookupState,
            lookupCountry: incoming.lookupCountry,
            lookupGrid: incoming.lookupGrid,
            lookupSource: incoming.lookupSource
        )
        let merged = LookupResolver.applying(contribution: contribution, to: base)
        let updated = LookupResolver.updatedDistance(for: merged, myGrid: config.myGrid)
        return HeardSpot(
            id: merged.id,
            call: merged.call,
            grid: merged.grid,
            lat: merged.lat,
            lon: merged.lon,
            mode: merged.mode,
            freq: merged.freq,
            report: merged.report,
            snr: merged.snr,
            timestamp: merged.timestamp,
            comment: merged.comment,
            band: merged.band,
            distanceMiles: updated.distanceMiles,
            isDX: updated.isDX,
            displayLocation: merged.displayLocation,
            lookupCity: merged.lookupCity,
            lookupState: merged.lookupState,
            lookupCountry: merged.lookupCountry,
            lookupGrid: merged.lookupGrid,
            lookupSource: merged.lookupSource
        )
    }

    private func rebuildIndex() {
        indexByKey.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        for (idx, spot) in spots.enumerated() {
            indexByKey[logicalKey(for: spot)] = idx
            indexByID[spot.id] = idx
        }
    }

    private func writeJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = SpotFeed(spots: spots)

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            fputs("spots.json encode failed: \(error)\n", stderr)
            return
        }

        do {
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            fputs("spots.json write failed at \(jsonURL.path): \(error)\n", stderr)
        }
    }
}

enum ParseError: Error { case outOfBounds, invalidMagic, invalidFormat }

struct DataReader {
    let data: Data
    private(set) var offset: Int = 0

    mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw ParseError.outOfBounds }
        let v = data[offset]
        offset += 1
        return v
    }

    mutating func readBool() throws -> Bool { try readUInt8() != 0 }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ParseError.outOfBounds }
        let s = data[offset..<(offset + 4)]
        offset += 4
        return s.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    mutating func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw ParseError.outOfBounds }
        let s = data[offset..<(offset + 8)]
        offset += 8
        return s.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readQByteArrayAsString() throws -> String? {
        let len = try readUInt32()
        if len == 0xffffffff { return nil }
        guard offset + Int(len) <= data.count else { throw ParseError.outOfBounds }
        let sub = data[offset..<(offset + Int(len))]
        offset += Int(len)
        return String(data: sub, encoding: .utf8) ?? String(decoding: sub, as: UTF8.self)
    }
}

enum WSJTXMessageType: UInt32 {
    case heartbeat = 0, status = 1, decode = 2, clear = 3, reply = 4, qsoLogged = 5, close = 6, replay = 7, haltTx = 8, freeText = 9, wsprDecode = 10, location = 11, loggedADIF = 12, highlightCallsign = 13, switchConfiguration = 14, configure = 15
}

struct WSJTXHeader {
    let magic: UInt32
    let schema: UInt32
    let type: UInt32
    let id: String?
}

struct DecodePacket {
    let isNew: Bool
    let snr: Int32
    let deltaTime: Double
    let deltaFrequency: UInt32
    let mode: String
    let message: String
    let lowConfidence: Bool
    let offAir: Bool
}

enum WSJTXParser {
    static let magic: UInt32 = 0xadbccbda

    static func parseHeader(_ data: Data) throws -> (DataReader, WSJTXHeader) {
        var r = DataReader(data: data)
        let magic = try r.readUInt32()
        guard magic == self.magic else { throw ParseError.invalidMagic }
        let schema = try r.readUInt32()
        let type = try r.readUInt32()
        let id = try r.readQByteArrayAsString()
        return (r, WSJTXHeader(magic: magic, schema: schema, type: type, id: id))
    }

    static func parseDecode(_ data: Data) throws -> DecodePacket {
        var (r, h) = try parseHeader(data)
        guard h.type == WSJTXMessageType.decode.rawValue else { throw ParseError.invalidFormat }
        let isNew = try r.readBool()
        _ = try r.readUInt32()
        let snr = try r.readInt32()
        let dt = try r.readDouble()
        let df = try r.readUInt32()
        let mode = try r.readQByteArrayAsString() ?? ""
        let msg = try r.readQByteArrayAsString() ?? ""
        let low = (try? r.readBool()) ?? false
        let offAir = (try? r.readBool()) ?? false
        return DecodePacket(isNew: isNew, snr: snr, deltaTime: dt, deltaFrequency: df, mode: mode, message: msg, lowConfidence: low, offAir: offAir)
    }

    static func parseStatus(_ data: Data) throws -> (dialHz: UInt64, mode: String) {
        var (r, h) = try parseHeader(data)
        guard h.type == WSJTXMessageType.status.rawValue else { throw ParseError.invalidFormat }
        let dialHz = try r.readUInt64()
        let mode = try r.readQByteArrayAsString() ?? ""
        return (dialHz, mode)
    }
}

struct Maidenhead {
    static func toCoordinate(_ locator: String) -> (lat: Double, lon: Double)? {
        let text = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [2,4,6,8,10].contains(text.count) else { return nil }
        let chars = Array(text.uppercased())
        guard chars.count >= 2 else { return nil }

        func idx(_ c: Character) -> Int? {
            guard let a = c.asciiValue else { return nil }
            return Int(a)
        }

        guard let a0 = idx(chars[0]), let a1 = idx(chars[1]) else { return nil }
        guard (65...82).contains(a0), (65...82).contains(a1) else { return nil }

        var lon = Double(a0 - 65) * 20.0 - 180.0
        var lat = Double(a1 - 65) * 10.0 - 90.0
        var lonWidth = 20.0
        var latHeight = 10.0

        if chars.count >= 4 {
            guard let c2 = chars[2].wholeNumberValue, let c3 = chars[3].wholeNumberValue else { return nil }
            lon += Double(c2) * 2.0
            lat += Double(c3) * 1.0
            lonWidth = 2.0
            latHeight = 1.0
        }
        if chars.count >= 6 {
            guard let a4 = idx(chars[4]), let a5 = idx(chars[5]) else { return nil }
            let x = a4 - 65, y = a5 - 65
            guard (0...23).contains(x), (0...23).contains(y) else { return nil }
            lon += Double(x) * (5.0 / 60.0)
            lat += Double(y) * (2.5 / 60.0)
            lonWidth = 5.0 / 60.0
            latHeight = 2.5 / 60.0
        }
        if chars.count >= 8 {
            guard let c6 = chars[6].wholeNumberValue, let c7 = chars[7].wholeNumberValue else { return nil }
            lon += Double(c6) * (0.5 / 60.0)
            lat += Double(c7) * (0.25 / 60.0)
            lonWidth = 0.5 / 60.0
            latHeight = 0.25 / 60.0
        }
        if chars.count >= 10 {
            guard let a8 = idx(chars[8]), let a9 = idx(chars[9]) else { return nil }
            let x = a8 - 65, y = a9 - 65
            guard (0...23).contains(x), (0...23).contains(y) else { return nil }
            lon += Double(x) * (0.5 / 60.0 / 24.0)
            lat += Double(y) * (0.25 / 60.0 / 24.0)
            lonWidth = 0.5 / 60.0 / 24.0
            latHeight = 0.25 / 60.0 / 24.0
        }
        return (lat + latHeight / 2.0, lon + lonWidth / 2.0)
    }
static func fromCoordinate(lat: Double, lon: Double, precision: Int = 6) -> String? {
    guard lat >= -90.0, lat <= 90.0, lon >= -180.0, lon <= 180.0 else { return nil }
    guard precision == 2 || precision == 4 || precision == 6 else { return nil }

    var adjLon = lon + 180.0
    var adjLat = lat + 90.0

    if adjLon >= 360.0 { adjLon = 359.999999 }
    if adjLat >= 180.0 { adjLat = 179.999999 }

    let fieldLon = Int(adjLon / 20.0)
    let fieldLat = Int(adjLat / 10.0)

    var locator = ""
    locator.append(Character(UnicodeScalar(65 + fieldLon)!))
    locator.append(Character(UnicodeScalar(65 + fieldLat)!))
    if precision == 2 { return locator }

    adjLon -= Double(fieldLon) * 20.0
    adjLat -= Double(fieldLat) * 10.0

    let squareLon = Int(adjLon / 2.0)
    let squareLat = Int(adjLat / 1.0)

    locator.append(String(squareLon))
    locator.append(String(squareLat))
    if precision == 4 { return locator }

    adjLon -= Double(squareLon) * 2.0
    adjLat -= Double(squareLat) * 1.0

    let subLon = Int(adjLon / (5.0 / 60.0))
    let subLat = Int(adjLat / (2.5 / 60.0))

    locator.append(Character(UnicodeScalar(65 + subLon)!))
    locator.append(Character(UnicodeScalar(65 + subLat)!))

    return locator
}
}

struct BandHelper {
    static func band(forMHz mhz: Double) -> String {
        switch mhz {
        case 1.8..<2.0: return "160M"
        case 3.5..<4.0: return "80M"
        case 5.0..<5.5: return "60M"
        case 7.0..<7.3: return "40M"
        case 10.1..<10.15: return "30M"
        case 14.0..<14.35: return "20M"
        case 18.068..<18.168: return "17M"
        case 21.0..<21.45: return "15M"
        case 24.89..<24.99: return "12M"
        case 28.0..<29.7: return "10M"
        case 50.0..<54.0: return "6M"
        case 144.0..<148.0: return "2M"
        case 222.0..<225.0: return "1.25M"
        case 420.0..<450.0: return "70CM"
        default: return ""
        }
    }
}

struct DistanceHelper {
    static func haversineMiles(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 3958.7613
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(dLon / 2), 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }
}

struct SpotExtractor {
    private static let callRegex = try! NSRegularExpression(
        pattern: #"^([A-Z0-9]{1,3}[0-9][A-Z0-9/]{1,})$"#,
        options: []
    )

    private static let gridRegex = try! NSRegularExpression(
        pattern: #"^([A-R]{2}[0-9]{2}(?:[A-X]{2})?)$"#,
        options: [.caseInsensitive]
    )

    private static let reportRegex = try! NSRegularExpression(
        pattern: #"\b(?:R?([+-]\d{2})|RR73|RRR|73)\b"#,
        options: []
    )

    private static let bannedTokens: Set<String> = ["CQ", "RR73", "RRR", "73"]

    static func extract(from decode: DecodePacket, dialHz: UInt64?, myGrid: String) -> HeardSpot? {
        let text = decode.message.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !decode.offAir else { return nil }

        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { return nil }

        guard let sender = senderCall(from: tokens) else { return nil }
        guard let grid = senderGrid(from: tokens) else { return nil }
        guard let coord = Maidenhead.toCoordinate(grid) else { return nil }

        let report = firstReport(in: text) ?? String(decode.snr)

        let freqMHz: String
        if let dialHz {
            let hz = Double(dialHz) + Double(decode.deltaFrequency)
            freqMHz = String(format: "%.6f", hz / 1_000_000.0)
        } else {
            freqMHz = ""
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let rawID = [grid, sender, decode.mode, freqMHz, report, text].joined(separator: "|")
        let digest = SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined()

        let mhz = Double(freqMHz) ?? 0
        let myCoord = Maidenhead.toCoordinate(myGrid) ?? (lat: 0.0, lon: 0.0)
        let distanceMiles = DistanceHelper.haversineMiles(
            lat1: myCoord.lat,
            lon1: myCoord.lon,
            lat2: coord.lat,
            lon2: coord.lon
        )

return HeardSpot(
    id: digest,
    call: sender,
    grid: grid,
    lat: coord.lat,
    lon: coord.lon,
    mode: decode.mode,
    freq: freqMHz,
    report: report,
    snr: Int(decode.snr),
    timestamp: stamp,
    comment: text,
    band: BandHelper.band(forMHz: mhz),
    distanceMiles: distanceMiles,
    isDX: distanceMiles >= 1000,
    displayLocation: nil,
    lookupCity: nil,
    lookupState: nil,
    lookupCountry: nil,
    lookupGrid: nil,
    lookupSource: nil
)
    }

    private static func senderCall(from tokens: [String]) -> String? {
    let cleaned = tokens.map { $0.uppercased() }
    guard !cleaned.isEmpty else { return nil }

    if cleaned[0] == "CQ" {
        for token in cleaned.dropFirst() {
            if isCallLike(token) {
                return token
            }
        }
        return nil
    }

    if cleaned.count >= 2, isCallLike(cleaned[0]), isCallLike(cleaned[1]) {
        return cleaned[1]
    }

    let calls = cleaned.filter { isCallLike($0) }
    if calls.count >= 2 { return calls[1] }
    return calls.first
}

private static func senderGrid(from tokens: [String]) -> String? {
    let cleaned = tokens.map { $0.uppercased() }
    guard !cleaned.isEmpty else { return nil }

    if cleaned[0] == "CQ" {
        var foundCall = false

        for token in cleaned.dropFirst() {
            if !foundCall {
                if isCallLike(token) {
                    foundCall = true
                }
                continue
            }

            if isGridLike(token) {
                return token
            }
        }

        return nil
    }

    if cleaned.count >= 3,
       isCallLike(cleaned[0]),
       isCallLike(cleaned[1]),
       isGridLike(cleaned[2]) {
        return cleaned[2]
    }

    let grids = cleaned.filter { isGridLike($0) }
    return grids.last
}

    private static func isCallLike(_ token: String) -> Bool {
        let text = token.uppercased()
        if bannedTokens.contains(text) || isGridLike(text) { return false }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = callRegex.firstMatch(in: text, options: [], range: range) else { return false }
        return match.range.location == 0 && match.range.length == ns.length
    }

    private static func isGridLike(_ token: String) -> Bool {
        let text = token.uppercased()
        if bannedTokens.contains(text) { return false }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = gridRegex.firstMatch(in: text, options: [], range: range) else { return false }
        return match.range.location == 0 && match.range.length == ns.length
    }

    private static func firstReport(in text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = reportRegex.firstMatch(in: text, options: [], range: range) else { return nil }

        if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
            return ns.substring(with: match.range(at: 1))
        }

        return nil
    }
}

final class MacNotifier {
    private let minDistanceMiles: Double
    private let dedupeWindowSeconds: TimeInterval
    private var seen = [String: Date]()
    private let stateQueue = DispatchQueue(label: "mac.notifier.state")
    private var isEnabled = false

    init(minDistanceMiles: Double, dedupeWindowSeconds: TimeInterval = 900) {
        self.minDistanceMiles = minDistanceMiles
        self.dedupeWindowSeconds = dedupeWindowSeconds
    }

    var enabled: Bool {
        stateQueue.sync { isEnabled }
    }

    func setEnabled(_ value: Bool) {
        stateQueue.sync { isEnabled = value }
    }

    func notifyIfNeeded(for spot: HeardSpot) {
        guard enabled else { return }
        guard spot.distanceMiles >= minDistanceMiles else { return }

        let now = Date()
        let key = spot.call.uppercased()

        seen = seen.filter { now.timeIntervalSince($0.value) < dedupeWindowSeconds }

        if let last = seen[key], now.timeIntervalSince(last) < dedupeWindowSeconds {
            return
        }
        seen[key] = now

        let title = "DX spot: \(spot.call)"
        let parts: [String?] = [
            "\(Int(spot.distanceMiles.rounded())) miles",
            spot.grid,
            spot.mode,
            spot.freq.isEmpty ? nil : "\(spot.freq) MHz"
        ]
        let body = parts.compactMap { $0 }.joined(separator: " · ")
        let script = "display notification \"\(Self.escape(body))\" with title \"\(Self.escape(title))\""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
        } catch {
            fputs("Notification exec error: \(error)\n", stderr)
        }
    }

    private static func escape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class BSDUDPListener {
    private let port: UInt16
    private let store: SpotStore
    private let adifWriter: ADIFWriter
    private let notifier: MacNotifier
    private let myGrid: String
    private let verbose: Bool
    private let lookupClient: HamQTHClient?
    private let hamDBClient: HamDBClient
    private let queue = DispatchQueue(label: "bsd.udp.listener")
    private var socketFD: Int32 = -1
    private var lastDialHz: UInt64?
    private var lastMode: String = ""

    init(port: UInt16, store: SpotStore, adifWriter: ADIFWriter, notifier: MacNotifier, myGrid: String, verbose: Bool, lookupClient: HamQTHClient?, hamDBClient: HamDBClient) {
        self.port = port
        self.store = store
        self.adifWriter = adifWriter
        self.notifier = notifier
        self.myGrid = myGrid
        self.verbose = verbose
        self.lookupClient = lookupClient
        self.hamDBClient = hamDBClient
    }

    func start() {
        socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            perror("socket")
            exit(1)
        }

        var one: Int32 = 1
        if setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            perror("setsockopt SO_REUSEADDR")
        }
        if setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            perror("setsockopt SO_BROADCAST")
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            perror("bind")
            exit(1)
        }

        print("UDP listener ready on 0.0.0.0:\(port)")
        queue.async { self.receiveLoop() }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65535)
        while true {
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(socketFD, &buffer, buffer.count, 0, sockPtr, &srcLen)
                }
            }
            if n > 0 {
                let data = Data(buffer[0..<Int(n)])
                handle(datagram: data)
            } else if n < 0 {
                perror("recvfrom")
                usleep(100_000)
            }
        }
    }

    private func handle(datagram: Data) {
        do {
            let (_, header) = try WSJTXParser.parseHeader(datagram)
            guard let type = WSJTXMessageType(rawValue: header.type) else { return }
            switch type {
            case .status:
                let status = try WSJTXParser.parseStatus(datagram)
                lastDialHz = status.dialHz
                lastMode = status.mode
                if verbose {
                    print("[STATUS] dial=\(status.dialHz) mode=\(status.mode)")
                }
            case .decode:
                let decode = try WSJTXParser.parseDecode(datagram)
                if let spot = SpotExtractor.extract(from: decode, dialHz: lastDialHz, myGrid: myGrid) {
                    store.add(spot)
                    adifWriter.append(spot: spot)
                    notifier.notifyIfNeeded(for: spot)
                    if let lookupClient {
    lookupClient.enrich(spot) { enriched in
        if let enriched,
           let lookupGrid = enriched.lookupGrid,
           lookupGrid.count >= 6 {
            self.store.replace(enriched)
            return
        }

        self.hamDBClient.enrich(enriched ?? spot) { hamdbEnriched in
            guard let hamdbEnriched else {
                if let enriched { self.store.replace(enriched) }
                return
            }
            self.store.replace(hamdbEnriched)
        }
    }
} else {
    self.hamDBClient.enrich(spot) { hamdbEnriched in
        guard let hamdbEnriched else { return }
        self.store.replace(hamdbEnriched)
    }
}
                    if verbose {
                        print("[SPOT] \(spot.call) \(spot.grid) \(spot.mode) \(spot.freq) \(spot.comment)")
                    }
                } else if verbose, decode.isNew {
                    print("[DECODE] \(decode.mode.isEmpty ? lastMode : decode.mode) \(decode.message)")
                }
            default:
                break
            }
        } catch ParseError.invalidMagic {
            if verbose {
                print("[IGNORED] Non-WSJT datagram, \(datagram.count) bytes")
            }
        } catch {
            if verbose {
                fputs("Parse error: \(error)\n", stderr)
            }
        }
    }
}

final class HTTPServer {
    private let listenerFD: Int32
    private let htmlURL: URL
    private let jsonURL: URL
    private let queue = DispatchQueue(label: "http.server")
    private let port: UInt16
    private let notifier: MacNotifier?

    init(port: UInt16, htmlURL: URL, jsonURL: URL, notifier: MacNotifier? = nil) {
        self.port = port
        self.htmlURL = htmlURL
        self.jsonURL = jsonURL
        self.notifier = notifier
        self.listenerFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            perror("http socket")
            exit(1)
        }

        var one: Int32 = 1
        _ = setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            perror("http bind")
            exit(1)
        }

        guard Darwin.listen(listenerFD, 16) >= 0 else {
            perror("listen")
            exit(1)
        }
    }

    func start() {
        print("HTTP server ready at http://127.0.0.1:\(port)/")
        queue.async { self.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            var addr = sockaddr()
            var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenerFD, &addr, &len)
            if client >= 0 {
                handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0 else {
            close(client)
            return
        }

        let request = String(decoding: buffer[0..<Int(count)], as: UTF8.self)
        let line = request.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let (method, path) = methodAndPathFromRequestLine(line)

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"), ("GET", "/udp-map-toy.html"):
            sendFile(url: htmlURL, contentType: "text/html; charset=utf-8", client: client)
        case ("GET", "/spots.json"):
            sendFile(url: jsonURL, contentType: "application/json; charset=utf-8", client: client)
        case ("GET", "/api/native-alerts"):
            sendNativeAlertsState(client: client)
        case ("POST", "/api/native-alerts/enable"):
            notifier?.setEnabled(true)
            sendNativeAlertsState(client: client)
        case ("POST", "/api/native-alerts/disable"):
            notifier?.setEnabled(false)
            sendNativeAlertsState(client: client)
        default:
            send(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not Found\n".utf8), client: client)
        }
        close(client)
    }

    private func sendNativeAlertsState(client: Int32) {
        let enabled = notifier?.enabled ?? false
        let json = "{\"available\":\(notifier != nil),\"enabled\":\(enabled)}"
        send(status: "200 OK", contentType: "application/json; charset=utf-8", body: Data(json.utf8), client: client)
    }

    private func methodAndPathFromRequestLine(_ line: String) -> (String, String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return ("GET", "/") }
        return (String(parts[0]), String(parts[1]))
    }

    private func sendFile(url: URL, contentType: String, client: Int32) {
        guard let data = try? Data(contentsOf: url) else {
            send(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Missing file\n".utf8), client: client)
            return
        }
        send(status: "200 OK", contentType: contentType, body: data, client: client)
    }

    private func send(status: String, contentType: String, body: Data, client: Int32) {
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        _ = response.withUnsafeBytes { ptr in
            Darwin.send(client, ptr.baseAddress, response.count, 0)
        }
    }
}

let config = Config()
let htmlTemplate = #"""
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>UDP Map Toy</title>
  <link rel="preconnect" href="https://api.fontshare.com">
  <link href="https://api.fontshare.com/v2/css?f[]=general-sans@400,500,600,700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin=""/>
  <style>
    :root, [data-theme="light"] {
      --font-body: 'General Sans', Inter, sans-serif;
      --color-bg:#f7f6f2; --color-surface:#f9f8f5; --color-surface-2:#fbfbf9; --color-text:#28251d;
      --color-text-muted:#66645f; --color-primary:#01696f; --radius:16px;
    }
    [data-theme="dark"] {
      --color-bg:#171614; --color-surface:#1c1b19; --color-surface-2:#201f1d; --color-text:#cdccca;
      --color-text-muted:#8f8d89; --color-primary:#4f98a3; --radius:16px;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; min-height: 100%; background: var(--color-bg); color: var(--color-text); font-family: var(--font-body); }
    body { display: grid; grid-template-rows: auto 1fr; }
    .topbar { display:flex; justify-content:space-between; gap:16px; align-items:center; padding:16px 20px; border-bottom:1px solid rgba(127,127,127,.18); background:var(--color-surface); position:sticky; top:0; z-index:1000; }
    .brand { display:flex; align-items:center; gap:12px; }
    .logo { width:28px; height:28px; color: var(--color-primary); }
    .brand h1 { margin:0; font-size:1.05rem; }
    .brand p { margin:0; color:var(--color-text-muted); font-size:.85rem; }
    .btn { border:1px solid rgba(127,127,127,.18); background:var(--color-surface-2); color:var(--color-text); border-radius:999px; min-height:42px; padding:0 14px; font:inherit; cursor:pointer; }
    .btn-sm { border:1px solid rgba(127,127,127,.18); background:var(--color-surface-2); color:var(--color-text); border-radius:999px; min-height:30px; padding:0 10px; font:inherit; font-size:.78rem; cursor:pointer; }
    .btn-sm.active { background:rgba(79,152,163,.18); border-color:rgba(79,152,163,.4); }
    .alerts-group { display:flex; align-items:center; gap:8px; }
    .alerts-label { color:var(--color-text-muted); font-size:.78rem; }
    .home-icon { color: var(--color-primary); filter: drop-shadow(0 1px 2px rgba(0,0,0,.35)); background:none; border:none; }
    .layout { display:grid; grid-template-columns:360px 1fr; height:calc(100vh - 75px); min-height:0; overflow:hidden; }
    .sidebar { background:var(--color-surface); padding:16px; overflow:hidden; border-right:1px solid rgba(127,127,127,.12); display:flex; flex-direction:column; min-height:0; gap:14px; }
    .map-wrap { position:relative; min-height:calc(100vh - 75px); }
    #map { position:absolute; inset:0; }
    .panel { background:var(--color-surface-2); border:1px solid rgba(127,127,127,.14); border-radius:var(--radius); padding:16px; }
    .stats { display:grid; grid-template-columns:repeat(2,1fr); gap:10px; }
    .stat { padding:12px; border-radius:12px; background:rgba(79,152,163,.10); }
    .label { color:var(--color-text-muted); font-size:.8rem; }
    .value { font-size:1.35rem; font-weight:700; }
    .spots { display:grid; gap:10px; overflow:auto; min-height:0; flex:1; padding-right:4px; }
    .spot { border:1px solid rgba(127,127,127,.12); border-radius:14px; padding:12px; background:var(--color-surface); cursor:pointer; }
    .spot.dx { box-shadow: inset 0 0 0 1px rgba(255,215,0,.22); }
    .badge { display:inline-flex; align-items:center; min-height:20px; padding:0 8px; border-radius:999px; font-size:.72rem; font-weight:700; letter-spacing:.03em; }
    .badge.dx { background:rgba(255,215,0,.14); color:#d9a300; border:1px solid rgba(217,163,0,.28); }
    .spot h3 { margin:0 0 4px 0; font-size:1rem; display:flex; align-items:center; justify-content:space-between; gap:8px; }
    .age-dot { width:12px; height:12px; border-radius:999px; flex:0 0 auto; box-shadow:0 0 0 2px rgba(255,255,255,.08); }
    .meta, .small { color:var(--color-text-muted); font-size:.84rem; }
    @media (max-width:900px) { .layout { grid-template-columns:1fr; grid-template-rows:minmax(280px,42vh) 1fr; height:calc(100vh - 75px); } .sidebar { border-right:none; border-bottom:1px solid rgba(127,127,127,.12); } .map-wrap { min-height:0; } }
  </style>
</head>
<body>
  <header class="topbar">
    <div class="brand">
      <svg class="logo" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2" aria-label="UDP Map Toy logo"><circle cx="16" cy="16" r="11"></circle><path d="M16 5v22M5 16h22"></path><path d="M9 9c5 4 9 10 14 14"></path></svg>
      <div><h1>UDP Map Toy</h1><p>Live local map for decoded heard spots</p></div>
    </div>
    <div style="display:flex; gap:14px; align-items:center;">
      <div class="alerts-group">
        <span class="alerts-label">Enable DX alerts</span>
        <button id="enableBrowserAlerts" class="btn-sm" aria-label="Enable browser DX alerts">Browser</button>
        <button id="enableMacAlerts" class="btn-sm" aria-label="Enable macOS DX alerts">macOS</button>
        <span id="notifyState" class="alerts-label"></span>
      </div>
      <button id="theme" class="btn" aria-label="Toggle theme">Theme</button>
    </div>
  </header>
  <div id="dxBanner" style="display:none; padding:10px 20px; border-bottom:1px solid rgba(127,127,127,.16); background:rgba(217,163,0,.12); color:var(--color-text);"></div><main class="layout">
    <aside class="sidebar">
      <section class="panel">
        <div class="stats">
          <div class="stat"><div class="label">Map entries</div><div id="visibleCount" class="value">0</div></div>
          <div class="stat"><div class="label">Unique calls</div><div id="uniqueCount" class="value">0</div></div>
          <div class="stat"><div class="label">Last update</div><div id="lastUpdate" class="value" style="font-size:1rem">—</div></div>
          <div class="stat"><div class="label">Feed</div><div id="feedStatus" class="value" style="font-size:1rem">idle</div></div>
        </div>
      </section>
      <section class="panel" style="display:flex; flex-direction:column; min-height:0; flex:1;"><h2 style="margin:0 0 6px 0; font-size:1rem; flex:0 0 auto;">Recent spots</h2><div class="small" style="margin-bottom:10px; flex:0 0 auto;">Green = newest, yellow = aging, red = oldest; DX shows spots over 1,000 miles.</div><div id="spots" class="spots"></div></section>
    </aside>
    <section class="map-wrap"><div id="map" aria-label="Map of heard spots"></div></section>
  </main>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
  <script>
    let map, layer, theme = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    let home = null;
    let longestMilesSeen = 0;
    let seenDX = new Set();
    let browserAlertsEnabled = false;
    let macAlertsAvailable = false;
    let macAlertsEnabled = false;
    const notifyState = document.getElementById('notifyState');
    const browserAlertsBtn = document.getElementById('enableBrowserAlerts');
    const macAlertsBtn = document.getElementById('enableMacAlerts');
    const dxBanner = document.getElementById('dxBanner');
    function setNotifyState(){
      const perm = ('Notification' in window) ? Notification.permission : 'unsupported';
      browserAlertsBtn.classList.toggle('active', browserAlertsEnabled);
      macAlertsBtn.classList.toggle('active', macAlertsEnabled);
      macAlertsBtn.disabled = !macAlertsAvailable;
      const parts = [];
      parts.push(`browser ${browserAlertsEnabled ? 'armed' : 'off'} (${perm})`);
      parts.push(`macOS ${macAlertsAvailable ? (macAlertsEnabled ? 'armed' : 'off') : 'unavailable'}`);
      notifyState.textContent = parts.join(' · ');
    }
    async function refreshMacAlertsState(){
      try {
        const r = await fetch('/api/native-alerts', { cache: 'no-store' });
        if(!r.ok) throw new Error(r.status);
        const s = await r.json();
        macAlertsAvailable = !!s.available;
        macAlertsEnabled = !!s.enabled;
      } catch(_) {
        macAlertsAvailable = false;
        macAlertsEnabled = false;
      }
      setNotifyState();
    }
    function showBanner(msg){
      dxBanner.textContent = msg;
      dxBanner.style.display = 'block';
      clearTimeout(showBanner._t);
      showBanner._t = setTimeout(()=>{ dxBanner.style.display = 'none'; }, 12000);
    }
    document.documentElement.setAttribute('data-theme', theme);
    document.getElementById('theme').addEventListener('click', () => {
      theme = theme === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', theme);
    });
    browserAlertsBtn.addEventListener('click', async () => {
      browserAlertsEnabled = !browserAlertsEnabled;
      if(browserAlertsEnabled && 'Notification' in window && Notification.permission === 'default') {
        try { await Notification.requestPermission(); } catch(_) {}
      }
      setNotifyState();
      showBanner(browserAlertsEnabled
        ? 'Browser DX alerts enabled. New long-distance record spots can notify when this tab is hidden.'
        : 'Browser DX alerts disabled.');
    });
    macAlertsBtn.addEventListener('click', async () => {
      if(!macAlertsAvailable) return;
      const endpoint = macAlertsEnabled ? '/api/native-alerts/disable' : '/api/native-alerts/enable';
      try {
        const r = await fetch(endpoint, { method: 'POST' });
        const s = await r.json();
        macAlertsAvailable = !!s.available;
        macAlertsEnabled = !!s.enabled;
      } catch(_) {}
      setNotifyState();
      showBanner(macAlertsEnabled
        ? 'macOS DX alerts enabled. New long-distance record spots trigger a system notification.'
        : 'macOS DX alerts disabled.');
    });
    setNotifyState();
    refreshMacAlertsState();
    map = L.map('map', { worldCopyJump: true }).setView([20,0], 2);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '&copy; OpenStreetMap contributors' }).addTo(map);
    layer = L.layerGroup().addTo(map);
    function e(t){const d=document.createElement('div');d.textContent=t??'';return d.innerHTML;}
    function ageMinutes(iso){const t=Date.parse(iso); return Number.isFinite(t)?Math.max(0,(Date.now()-t)/60000):9999;}
    function ageColor(iso){const m=Math.min(ageMinutes(iso),120); const hue=120-(m/120)*120; return `hsl(${hue} 72% 48%)`;}
    function miles(v){return Math.round(Number(v)||0).toLocaleString();}
    function maybeNotifyDX(s){
      if(!s.isDX) return;
      const key = `${s.call}|${s.grid}|${s.timestamp}`;
      const isRecord = s.distanceMiles > longestMilesSeen;
      if(isRecord) longestMilesSeen = s.distanceMiles;
      if(seenDX.has(key)) return;
      seenDX.add(key);
      showBanner(`DX spot: ${s.call} · ${miles(s.distanceMiles)} miles · ${s.grid} · ${s.mode} ${s.freq}`);
      if(!browserAlertsEnabled) return;
      if(document.visibilityState === 'visible' && !isRecord) return;
      if('Notification' in window && Notification.permission === 'granted') {
        new Notification(`DX spot: ${s.call}`, { body: `${miles(s.distanceMiles)} miles · ${s.grid} · ${s.mode} ${s.freq}` });
      }
    }
    const homeIcon = L.divIcon({
      className: 'home-icon',
      html: '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-label="Home location"><path d="M12 2.6 2 11h3v10h6v-6h2v6h6V11h3z"/></svg>',
      iconSize: [22,22],
      iconAnchor: [11,11]
    });
    function render(spots){
      layer.clearLayers();
      const bounds=[];

      if(home){
        L.marker(home, { icon: homeIcon, zIndexOffset: 1000 })
          .bindPopup('<div class="popup"><b>Home</b></div>')
          .addTo(layer);
        bounds.push(home);
      }

    function escapeHtml(v){
  return String(v ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  }[ch]));
}

for(const s of spots){
  const c = ageColor(s.timestamp);
  const strong = s.snr > 0;
  const weight = strong ? 3 : (s.isDX ? 4 : 2);
  const radius = s.isDX ? 9 : 7;
  const stroke = strong ? '#ffd400' : c;

  const overAir4 = String(s.grid || '').toUpperCase().slice(0,4);
  const lookup4 = String(s.lookupGrid || '').toUpperCase().slice(0,4);
  const preciseLookupMatch = (
    s.lookupGrid &&
    s.lookupGrid.length >= 6 &&
    overAir4.length === 4 &&
    lookup4 === overAir4
  );

  const derivedCoord = preciseLookupMatch ? maidenToLatLong(s.lookupGrid) : null;
  const plotCoord = derivedCoord || { lat: s.lat, lon: s.lon };

  const marker = L.circleMarker([plotCoord.lat, plotCoord.lon], {
    radius: radius,
    color: stroke,
    weight: weight,
    fillColor: c,
    fillOpacity: s.isDX ? 0.9 : 0.78
  }).addTo(layer);

  const locationText = s.displayLocation || s.grid;
  const lookupNote = s.lookupSource ? `<div><b>Source:</b> ${e(s.lookupSource)}</div>` : '';
  const distanceLine = preciseLookupMatch ? `<div><b>Distance:</b> ${miles(s.distanceMiles)} mi</div>` : '';
  const hasBetterLookup = s.lookupGrid && s.lookupGrid.length >= 6 && s.lookupGrid.toUpperCase() !== String(s.grid || '').toUpperCase();

  const gridNote = hasBetterLookup
    ? `<div><b>Lookup grid:</b> ${e(s.lookupGrid)}${
        overAir4.length === 4
          ? (lookup4 === overAir4
              ? ` <span class="small">(matches on-air grid)</span>`
              : ` <span class="small">(differs from on-air grid)</span>`)
          : ''
      }</div>`
    : '';

  marker.bindPopup(`
    <div class="popup">
      <div><b>${e(s.call)}</b></div>
      <div><b>Location:</b> ${e(locationText)}</div>
      <div><b>Grid:</b> ${e(s.grid)}</div>
      ${gridNote}
      <div><b>Mode:</b> ${e(s.mode || '')}</div>
      <div><b>Freq:</b> ${e(s.freq || '')}</div>
      <div><b>Report:</b> ${e(String(s.report || ''))}</div>
      ${distanceLine}
      ${lookupNote}
      <div><b>Message:</b> ${e(s.comment || '')}</div>
    </div>
  `);

  s.marker = marker;

  if(s.isDX && home){
    L.polyline([home, [plotCoord.lat, plotCoord.lon]], {
      color: c,
      weight: 1.5,
      opacity: 0.55,
      dashArray: '5 6'
    }).addTo(layer);
  }

  maybeNotifyDX(s);
  bounds.push([plotCoord.lat, plotCoord.lon]);
}

      if(bounds.length) map.fitBounds(bounds,{padding:[30,30],maxZoom:6});
      document.getElementById('visibleCount').textContent=String(spots.length);
      document.getElementById('uniqueCount').textContent=String(new Set(spots.map(s=>s.call).filter(Boolean)).size);
      document.getElementById('lastUpdate').textContent=new Date().toLocaleTimeString();
      const wrap=document.getElementById('spots'); wrap.innerHTML='';
  
      const byCall = new Map();

      function spotScore(s){
        const hasLocation = s.displayLocation ? 1 : 0;
        const lookupLen = String(s.lookupGrid || '').length;
        const ts = Date.parse(s.timestamp || '') || 0;
        return hasLocation * 1000000000000000 + lookupLen * 1000000000000 + ts;
      }

      for (const s of spots) {
        const key = String(s.call || '').toUpperCase();
        if (!key) continue;
        const prior = byCall.get(key);
        if (!prior || spotScore(s) > spotScore(prior)) {
          byCall.set(key, s);
        }
      }

      const recent = Array.from(byCall.values()).sort((a,b) => {
        const at = Date.parse(a.timestamp || '') || 0;
        const bt = Date.parse(b.timestamp || '') || 0;
        return bt - at;
      });

      for(const s of recent.slice(0,25)){
        const c=ageColor(s.timestamp);
        const el=document.createElement('article'); el.className='spot' + (s.isDX ? ' dx' : '');
        el.style.borderColor=c;
        el.innerHTML=`<h3><span>${e(s.call)}</span><span class="age-dot" style="background:${c}"></span></h3><div class="meta">${e(s.displayLocation || s.grid)} · ${e(s.mode)} · ${e(s.freq)}${s.isDX ? ` · <span class="badge dx">DX ${miles(s.distanceMiles)} mi</span>` : ''}</div><div class="small">${e(s.timestamp)}</div><div class="small">${e(s.comment)}</div>`;

    el.addEventListener('click', () => {
  const ll = s.marker?.getLatLng?.();
  if(ll){
    map.setView([ll.lat, ll.lng], 10);
  }
  s.marker?.openPopup();
});

    wrap.appendChild(el);

    }
}
    async function refresh(){
      document.getElementById('feedStatus').textContent='loading';
      try {
        const r=await fetch('/spots.json',{cache:'no-store'}); if(!r.ok) throw new Error(r.status);
        const p=await r.json();
        const spots = Array.isArray(p)?p:(p.spots||[]);
        if(!home && spots.length){
          const dx = spots.find(s => Number.isFinite(s.distanceMiles));
          if(dx && Number.isFinite(dx.lat) && Number.isFinite(dx.lon)) {}
        }
        render(spots);
        document.getElementById('feedStatus').textContent='ok';
      } catch(err) { document.getElementById('feedStatus').textContent='error'; console.error(err); }
    }

    function maidenToLatLong(g){
  if(!g) return null;
  const s = String(g).trim().toUpperCase();
  if(!(s.length === 4 || s.length === 6)) return null;

  const A = 'A'.charCodeAt(0);

  let lon = (s.charCodeAt(0) - A) * 20 - 180;
  let lat = (s.charCodeAt(1) - A) * 10 - 90;

  const dLon = Number(s[2]);
  const dLat = Number(s[3]);
  if(!Number.isFinite(dLon) || !Number.isFinite(dLat)) return null;

  lon += dLon * 2;
  lat += dLat * 1;

  if(s.length === 6){
    const subLon = s.charCodeAt(4) - A;
    const subLat = s.charCodeAt(5) - A;
    if(subLon < 0 || subLon > 23 || subLat < 0 || subLat > 23) return null;

    lon += subLon * (5 / 60);
    lat += subLat * (2.5 / 60);
    lon += (5 / 60) / 2;
    lat += (2.5 / 60) / 2;
  } else {
    lon += 1;
    lat += 0.5;
  }

  return { lat, lon };
}

home = (() => {
  const myGrid = "\#(config.myGrid)";
  const grid = myGrid.trim();
  return maidenToLatLong(grid);
})();

    refresh(); setInterval(refresh, 15000);
  </script>
</body>
</html>
"""#

if let htmlData = htmlTemplate.data(using: .utf8) {
    do {
        try htmlData.write(to: config.htmlPath, options: .atomic)
    } catch {
        fputs("HTML write failed at \(config.htmlPath.path): \(error)\n", stderr)
    }
} else {
    fputs("HTML encoding failed for \(config.htmlPath.path)\n", stderr)
}
let store = SpotStore(jsonURL: config.jsonPath)
let adifWriter = ADIFWriter(url: config.adifPath, config: config)
let notifier = MacNotifier(minDistanceMiles: config.notifyDistanceMiles)
let lookupClient = HamQTHClient(
    username: config.hamQTHUser ?? ProcessInfo.processInfo.environment["HAMQTH_USER"],
    password: config.hamQTHPassword ?? ProcessInfo.processInfo.environment["HAMQTH_PASSWORD"],
    programName: "udp-map-toy"
)
let hamDBClient = HamDBClient()
let udp = BSDUDPListener(port: config.udpPort, store: store, adifWriter: adifWriter, notifier: notifier, myGrid: config.myGrid, verbose: config.verbose, lookupClient: lookupClient, hamDBClient: hamDBClient)
let http = HTTPServer(port: config.httpPort, htmlURL: config.htmlPath, jsonURL: config.jsonPath, notifier: notifier)
udp.start()
http.start()
print("HTML: \(config.htmlPath.path)")
print("JSON: \(config.jsonPath.path)")
print("ADIF: \(config.adifPath.path)")
print("Notify distance: \(Int(config.notifyDistanceMiles.rounded())) miles")
print("Open: http://127.0.0.1:\(config.httpPort)/")
dispatchMain()
