// SPDX-License-Identifier: GPL-3.0-only
//
//  Apricot-Bridging-Header.h
//  Exposes the C SSTV core to Swift.
//
//  Core/ holds files copied unchanged from the iPod repository
//  (github.com/SodaGray/apricot-sstv, commit a238f65):
//    sstv_dsp.c/.h  the decoder (from the repository root)
//    enc.c/.h       the encoder (from host/)
//  Fix bugs there first, then copy them here again, so every app runs
//  the same code.
//

#include "Core/sstv_dsp.h"
#include "Core/enc.h"
