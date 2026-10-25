# pips-xsct.tcl - PIPS over JTAG (XSCT): the batcher/logger config register
# (regfile), the log DMA, and the TLP log in DDR. The same AXI targets the
# host reaches through BAR0 with the pips tool. Use it when the host path is
# down, or to cross-check it: `pips cfg` on the host must read what pips_cfg
# reads here.
#
#   xsct% source scripts/pips/pips-xsct.tcl
#   xsct% pips_connect                        ;# TCP:192.17.103.45:3121, target 1
#   xsct% pips_connect TCP:<host>:3121 <id>   ;# other hw_server / target (`targets` lists them)
#   xsct% pips_cfg                            ;# reg0 at 0xA4000000 and reg1 (drain), decoded,
#                                             ;#   the design ID and its TLP log format
#   xsct% pips_cfg_set depth 8 time 0x16      ;# read-modify-write: depth time mrd log raw
#   xsct% pips_cfg_set cap 1                  ;# reg1 drain_depth_cap (design 0x0a03 on)
#   xsct% pips_status                         ;# page batcher status at +0x24-0x2C (0x0a06 on;
#                                             ;#   reading clears it): spills, stuck, MRd wait
#   xsct% pips_dma                            ;# S2MM registers at 0xA4010000, decoded
#   xsct% pips_log_start                      ;# arm the DMA on the log region, log_enable 0 -> 1
#   xsct% pips_log_stop                       ;# log_enable 1 -> 0, wait for the DMA, print the trailer
#   xsct% pips_log_wait                       ;# the same without ending the recording (region full)
#   xsct% pips_log_dump log-id0a04.bin        ;# the bytes the DMA wrote, to a file. Name it with the
#                                             ;#   design ID (it picks the record format), then anywhere:
#                                             ;#   python3 scripts/pips/pips-log-decode.py log-id0a04.bin
#
# The host reads the log region from BAR0 (LOG_BASE, LOG_BYTES); XSCT cannot
# reach BAR0 registers, so the build constants are repeated below (pips.tcl
# pips_log_ddr_base, pips_log_region_bytes). Change them together. DDR is
# read through the PMC's NoC port (axi_noc_0 S01) at JTAG speed: a full
# 4 MiB dump takes a while. Register offsets and bits: pips_regs.h.

set pips_regfile   0xA4000000
set pips_dma       0xA4010000
set pips_log_base  0x00000000
set pips_log_bytes 4194304

proc pips_hex {v} { return [format 0x%08x $v] }
proc pips_rd {addr} { return [lindex [mrd -value [format 0x%x $addr] 1] 0] }
proc pips_wr {addr val} { mwr [format 0x%x $addr] [format 0x%08x $val] }
proc pips_dma_rd {off} { return [pips_rd [expr {$::pips_dma + $off}]] }
proc pips_dma_wr {off val} { pips_wr [expr {$::pips_dma + $off}] $val }

proc pips_connect {{url TCP:192.17.103.45:3121} {target 1}} {
    connect -url $url
    targets $target
    configparams force-mem-access 1
    puts [pips_cfg_decode [pips_rd $::pips_regfile]]
}

proc pips_cfg_decode {v} {
    return [format "cfg=0x%08x depth_threshold=%d time_threshold=%d batch_mrd=%d log_enable=%d" \
        $v [expr {$v & 0xFF}] [expr {($v >> 8) & 0xFF}] [expr {($v >> 16) & 1}] [expr {($v >> 24) & 1}]]
}

# The build's design ID (regfile + 0x20) as 0x0a04, or none: builds from
# before the register answer it with a decode error.
proc pips_design {} {
    if {[catch {set id [pips_rd [expr {$::pips_regfile + 0x20}]]}]} { return none }
    return [format 0x%04x [expr {$id & 0xFFFF}]]
}

proc pips_cfg {} {
    set v [pips_rd $::pips_regfile]
    puts [pips_cfg_decode $v]
    set id [pips_design]
    if {$id ne "none" && $id >= 0x0a03} {
        set d [pips_rd [expr {$::pips_regfile + 0x4}]]
        puts "drain=[pips_hex $d] drain_depth_cap=[expr {$d & 1}]"
    } else {
        puts "drain=none drain_depth_cap=0"
    }
    if {$id ne "none" && $id >= 0x0a06} {
        set p [pips_rd [expr {$::pips_regfile + 0xC}]]
        set t [pips_rd [expr {$::pips_regfile + 0x8}]]
        puts [format "pb=0x%08x page_batch_en=%d ctrl_push_off=%d grant_quantum=%d" $p \
            [expr {$p & 1}] [expr {($p >> 8) & 1}] [expr {($p >> 16) & 0xFFF}]]
        puts [format "thr=0x%08x ctrl_dw_thr_0=%d ctrl_dw_thr_1=%d" $t [expr {$t & 0x7FF}] [expr {($t >> 16) & 0x7FF}]]
    }
    puts "design_id=$id"
    puts "log_format=[expr {$id ne "none" && $id >= 0x0a04 ? "v2" : "v1"}]"
    return $v
}

# The page batcher's status (design 0x0a06 on), as `pips status` reads it:
# reading 0x24 returns the sticky flags and CLEARS them, and latches 0x28/0x2C.
# Over JTAG it works when PCIe does not: read it before reprogramming a hung
# switch. A stuck bit or a huge MRd wait points at the batcher.
proc pips_status {} {
    set id [pips_design]
    if {$id eq "none" || $id < 0x0a06} { puts "status=none (design $id)"; return }
    set f [pips_rd [expr {$::pips_regfile + 0x24}]]
    set c [pips_rd [expr {$::pips_regfile + 0x28}]]
    set w [pips_rd [expr {$::pips_regfile + 0x2C}]]
    puts [format "stat_flags=0x%08x ovf0=%d ovf1=%d stuck=%d" $f [expr {$f & 1}] [expr {($f >> 1) & 1}] [expr {($f >> 2) & 1}]]
    puts [format "ovf_count_0=%d ovf_count_1=%d" [expr {$c & 0xFFFF}] [expr {$c >> 16}]]
    puts [format "mrd_wait_max_us_0=%.2f mrd_wait_max_us_1=%.2f (cycles %d %d)" \
        [expr {($w & 0xFFFF) * 0.004}] [expr {($w >> 16) * 0.004}] [expr {$w & 0xFFFF}] [expr {$w >> 16}]]
}

proc pips_cfg_set {args} {
    if {[llength $args] % 2} { error "usage: pips_cfg_set ?depth N? ?time N? ?mrd 0|1? ?log 0|1? ?raw V? ?cap 0|1?" }
    set v [pips_rd $::pips_regfile]
    set cap ""
    foreach {k n} $args {
        switch -- $k {
            depth   { set v [expr {($v & ~0xFF) | ($n & 0xFF)}] }
            time    { set v [expr {($v & ~0xFF00) | (($n & 0xFF) << 8)}] }
            mrd     { set v [expr {$n ? ($v | 0x10000) : ($v & ~0x10000)}] }
            log     { set v [expr {$n ? ($v | 0x1000000) : ($v & ~0x1000000)}] }
            raw     { set v [expr {$n & 0xFFFFFFFF}] }
            cap     { set cap [expr {$n ? 1 : 0}] }
            default { error "unknown field $k (depth time mrd log raw cap)" }
        }
    }
    if {$cap ne ""} {
        set id [pips_design]
        if {$id eq "none" || $id < 0x0a03} { error "cap: design $id has no drain config register (needs 0x0a03 or later)" }
    }
    pips_wr $::pips_regfile $v
    if {$cap ne ""} { pips_wr [expr {$::pips_regfile + 0x4}] $cap }
    return [pips_cfg]
}

proc pips_dmasr_flags {sr} {
    set f {}
    foreach {bit name} {0 halted 1 idle 3 sg_included 4 int_err 5 slv_err 6 dec_err 12 ioc 13 dly_irq 14 err_irq} {
        if {($sr >> $bit) & 1} { lappend f $name }
    }
    if {![llength $f]} { return running }
    return [join $f]
}

proc pips_dma {} {
    set cr [pips_dma_rd 0x30]
    set sr [pips_dma_rd 0x34]
    puts "dmacr=[pips_hex $cr] run=[expr {$cr & 1}]"
    puts "dmasr=[pips_hex $sr] [pips_dmasr_flags $sr]"
    puts "da=[pips_hex [pips_dma_rd 0x48]]"
    puts "length=[pips_dma_rd 0x58]"
    return $sr
}

# Same sequence as pips.c log_start(): telemetry_dma_format.md §7, steps 1-3.
proc pips_log_start {} {
    set cfg [pips_rd $::pips_regfile]
    if {$cfg & 0x1000000} {
        puts "log_enable was 1: clearing it"
        pips_wr $::pips_regfile [expr {$cfg & ~0x1000000}]
        after 1
    }
    set sr [pips_dma_rd 0x34]
    for {set i 0} {$i < 100 && !($sr & 0x73)} {incr i} { after 1; set sr [pips_dma_rd 0x34] }
    if {($sr & 0x70) || !($sr & 0x3)} {
        puts "DMA [pips_dmasr_flags $sr]: resetting it"
        pips_dma_wr 0x30 0x4
        for {set i 0} {$i < 100 && ([pips_dma_rd 0x30] & 0x4)} {incr i} { after 1 }
    }
    pips_dma_wr 0x34 0x7000
    pips_dma_wr 0x30 0x1
    for {set i 0} {[pips_dma_rd 0x34] & 0x1} {incr i} {
        if {$i == 10} { error "the DMA stays halted after RS=1" }
        after 1
    }
    for {set i 0} {1} {incr i} {
        pips_dma_wr 0x48 $::pips_log_base
        pips_dma_wr 0x58 $::pips_log_bytes
        after 2
        set sr [pips_dma_rd 0x34]
        if {$sr & 0x70} { error "DMA error right after arming: [pips_dmasr_flags $sr]" }
        if {!($sr & 0x1002)} { break }
        puts "the DMA took [pips_dma_rd 0x58] stale bytes (the end of an earlier recording); re-arming"
        pips_dma_wr 0x34 0x7000
        if {$i == 2} { error "the DMA keeps completing at once" }
    }
    set cfg [pips_rd $::pips_regfile]
    pips_wr $::pips_regfile [expr {$cfg | 0x1000000}]
    puts "recording started: DDR [pips_hex $::pips_log_base] + $::pips_log_bytes bytes"
}

proc pips_log_wait {{timeout_ms 2000}} {
    set t0 [clock milliseconds]
    while {!([set sr [pips_dma_rd 0x34]] & 0x1073)} {
        if {[clock milliseconds] - $t0 > $timeout_ms} {
            puts "dmasr=[pips_hex $sr]: still waiting for log data (recording open?)"
            return -1
        }
        after 1
    }
    puts "dmasr=[pips_hex $sr] [pips_dmasr_flags $sr]"
    if {$sr & 0x70} { error "DMA error" }
    if {!($sr & 0x1002)} { error "the DMA is halted, not armed: pips_log_start first" }
    set bytes [pips_dma_rd 0x58]
    set a [expr {$::pips_log_base + $bytes - 16}]
    set w [mrd -value [format 0x%x $a] 4]
    set info [expr {([lindex $w 3] >> 16) & 0xFF}]
    if {$info != 0x88} { error "the last record is not a trailer (info [format 0x%02x $info])" }
    set reason [expr {[lindex $w 3] & 0xFF}]
    puts "bytes_written=$bytes n_records=[lindex $w 0] n_dropped=[lindex $w 1]\
          duration_cycles=[lindex $w 2] stop_reason=[expr {$reason == 1 ? "enable_low" : $reason == 2 ? "region_full" : $reason}]"
    return $bytes
}

proc pips_log_stop {{timeout_ms 2000}} {
    set cfg [pips_rd $::pips_regfile]
    if {$cfg & 0x1000000} { pips_wr $::pips_regfile [expr {$cfg & ~0x1000000}] }
    return [pips_log_wait $timeout_ms]
}

proc pips_log_dump {file {bytes ""}} {
    if {$bytes eq ""} {
        set sr [pips_dma_rd 0x34]
        if {!($sr & 0x1002)} { error "the DMA has not finished ([pips_dmasr_flags $sr]): pips_log_stop first, or give bytes" }
        set bytes [pips_dma_rd 0x58]
    }
    mrd -bin -file $file [format 0x%x $::pips_log_base] [expr {$bytes / 4}]
    set id [pips_design]
    puts "wrote $bytes bytes from DDR [pips_hex $::pips_log_base] to $file (design $id)"
    if {$id ne "none" && ![string match "*-id[string range $id 2 end]*" $file]} {
        puts "decode it with: pips-log-decode.py $file --design-id $id   (or name it *-id[string range $id 2 end].bin)"
    }
}
