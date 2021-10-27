# Set to 1 to create a packet capture file in $TMPDIR for each test
incr capture 0

if {![dict exists [namespace ensemble configure dict -map] getdef]} {
    proc addmap {cmd args} {
	set map [dict merge [namespace ensemble configure $cmd -map] $args]
	namespace ensemble configure $cmd -map $map
    }

    namespace eval ::tcl::dict {
	proc getdef {dict args} {
	    ::set path [lrange $args 0 end-1]
	    return [if {[exists $dict {*}$path]} {
		get $dict {*}$path
	    } else {
		lindex $args end
	    }]
	}
    }

    addmap dict getwithdefault ::tcl::dict::getdef getdef ::tcl::dict::getdef
}

customMatch constrained [list apply [list {expect result} {
    foreach {constraint mode value} $expect {
	if {$constraint eq "default" || [testConstraint $constraint]} {
	    return [tcltest::CompareStrings $result $value $mode]
	}
    }
    return 0
}]]

proc varwait {varname {timeout 5000}} {
    upvar #0 $varname var
    set id [after $timeout [list set $varname {result timeout}]]
    uplevel #0 [list vwait $varname]
    after cancel $id
    return $var
}

proc sleep {{timeout 1000}} {
    varwait sleep $timeout
    return
}

if {$capture} {
    if {[info exists env(TMPDIR)]} {
	set tmpdir $env(TMPDIR)
    } else {
	set tmpdir /tmp
    }

    trace add execution test enter [list apply [list {cmd op} {
	startcapture [lindex $cmd 1] {port 1883 or port 2883}
    }]]
    trace add execution test leave [list apply [list {args} {
	stopcapture
    }]]

    proc startcapture {name {filter {port 1883}}} {
	global cap tmpdir
	set file [file join $tmpdir $name.pcapng]
	set cap [exec dumpcap -q -i lo -f $filter -w $file 2>/dev/null &]
	sleep 500
    }

    proc stopcapture {} {
	global cap
	sleep 500
	catch {exec kill $cap}
    }
}
