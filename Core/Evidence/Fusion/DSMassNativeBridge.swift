// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

enum DSMassNativeBridge {
static func dempsterCombine(_ first: DSMassFunction, _ second: DSMassFunction) -> (mass: DSMassFunction, conflict: Double, usedYager: Bool)? {
#if canImport(CAetherNativeBridge)
var lhs = toNative(first)
var rhs = toNative(second)
var result = aether_ds_combine_result_t()
let rc = aether_ds_combine_dempster(&lhs, &rhs, &result)
guard rc == 0 else { return nil }
return (fromNative(result.mass), result.conflict, result.used_yager != 0)
#else
_ = first
_ = second
return nil
#endif
}

static func yagerCombine(_ first: DSMassFunction, _ second: DSMassFunction) -> DSMassFunction? {
#if canImport(CAetherNativeBridge)
var lhs = toNative(first)
var rhs = toNative(second)
var out = aether_ds_mass_t()
let rc = aether_ds_combine_yager(&lhs, &rhs, &out)
return rc == 0 ? fromNative(out) : nil
#else
_ = first
_ = second
return nil
#endif
}

static func combine(_ first: DSMassFunction, _ second: DSMassFunction) -> DSMassFunction? {
#if canImport(CAetherNativeBridge)
var lhs = toNative(first)
var rhs = toNative(second)
var out = aether_ds_mass_t()
let rc = aether_ds_combine_auto(&lhs, &rhs, &out)
return rc == 0 ? fromNative(out) : nil
#else
_ = first
_ = second
return nil
#endif
}

static func discount(_ mass: DSMassFunction, reliability: Double) -> DSMassFunction? {
#if canImport(CAetherNativeBridge)
var input = toNative(mass)
var out = aether_ds_mass_t()
let rc = aether_ds_discount(&input, reliability, &out)
return rc == 0 ? fromNative(out) : nil
#else
_ = mass
_ = reliability
return nil
#endif
}

static func fromDeltaMultiplier(_ value: Double) -> DSMassFunction? {
#if canImport(CAetherNativeBridge)
var out = aether_ds_mass_t()
let rc = aether_ds_from_delta_multiplier(value, &out)
return rc == 0 ? fromNative(out) : nil
#else
_ = value
return nil
#endif
}

static func sealed(_ mass: DSMassFunction) -> DSMassFunction? {
#if canImport(CAetherNativeBridge)
var input = toNative(mass)
var out = aether_ds_mass_t()
let rc = aether_ds_mass_sealed(&input, &out)
return rc == 0 ? fromNative(out) : nil
#else
_ = mass
return nil
#endif
}

#if canImport(CAetherNativeBridge)
private static func toNative(_ mass: DSMassFunction) -> aether_ds_mass_t {
var out = aether_ds_mass_t()
out.occupied = mass.occupied
out.free_mass = mass.free
out.unknown = mass.unknown
return out
}

private static func fromNative(_ mass: aether_ds_mass_t) -> DSMassFunction {
DSMassFunction(rawOccupied: mass.occupied, rawFree: mass.free_mass, rawUnknown: mass.unknown)
}
#endif
}
