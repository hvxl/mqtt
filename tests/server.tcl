package require broker 2

source [file join [file dirname [info script]] util.tcl]

if {![catch {open "|mosquitto_sub --help"} fd]} {
    # Stop at the first empty line or EOF
    while {[gets $fd line] > 0} {
	if {[scan $line {mosquitto_sub version %s} version] == 1} break
    }
    catch {close $fd}
    unset -nocomplain fd line

    # Support for MQTT v5 was added in version 1.6
    if {[package vsatisfies $version 1.6-]} {testConstraint MQTTV5 1}
}

oo::class create client {
    constructor {{ver 4} {pattern #} args} {
	set version [version $ver]
	variable fd \
	  [open "|mosquitto_sub -V $version -t [list $pattern] -v $args"]
	fconfigure $fd -blocking 0
	sleep 100
    }

    destructor {
	my kill
    }

    method collect {{ms 1000}} {
	my variable fd collect
	set collect {}
	set var [namespace which -variable collect]
	fileevent $fd readable [list [namespace which my] Collect]
	set id [after $ms [list set $var timeout]]
	vwait $var
	after cancel $id
	fileevent $fd readable {}
	return $collect
    }

    method Collect {} {
	my variable fd collect
	append collect [read -nonewline $fd]
    }

    method kill {{signal TERM}} {
	my variable fd
	if {$fd ne ""} {
	    exec kill -s $signal [pid $fd]
	    set fd [close $fd]
	}
	my destroy
    }
}

proc version {str} {
    switch $str {
	3 - 3.1 - 31 - v31 - mqttv31 {
	    return mqttv31
	}
	5 - v5 - mqttv5 {
	    return mqttv5
	}
	default {
	    return mqttv311
	}
    }
}

proc mosquitto_pub {args} {
    global pubfd
    set pubfd [open |[info level 0]]
    fconfigure $pubfd -blocking 0
    coroutine $pubfd apply [list {} {
	global pubfd
	fileevent $pubfd readable [list [info coroutine] data]
	while {![eof $pubfd]} {
	    yield
	    read $pubfd
	}
	close $pubfd
	set pubfd ""
    }]
    vwait pubfd
}

proc putts {str} {
    puts "[clock milliseconds] $str"
}

file delete tcltest.db
# broker log putts
broker create server tcltest.db
server listen

proc kill {} {
    foreach n [info class instances client] {
	$n destroy
    }
}
