package require mqtt

source [file join [file dirname [info script]] util.tcl]

# mqtt log puts

catch {exec mosquitto -h} output
if {[scan $output {mosquitto version %s} mosquitto] == 1} {
    # Mosquitto 1.6 added support for MQTT v5
    if {[package vsatisfies $mosquitto 1.6-]} {testConstraint MQTTV5 1}
    # The broker now sends the receive-maximum property for MQTT v5 CONNACKs.
    # https://github.com/eclipse/mosquitto/commit/4ae8971ce
    if {[package vsatisfies $mosquitto 2.0-]} {testConstraint FIX4AE8971 1}
    # Fix LWT messages not being delivered if per_listener_settings was s…
    # https://github.com/eclipse/mosquitto/commit/7551a29
    if {![package vsatisfies $mosquitto 2.0.12-2.0.12]} {testConstraint FIX7551A29 1}
    # Fix broker sending duplicate CONNACK on failed MQTT v5 reauthentication.
    # https://github.com/eclipse/mosquitto/commit/5cae4d1
    if {[package vsatisfies $mosquitto 2.0.13-]} {testConstraint FIX5CAE4D1 1}
    # Send DISCONNECT With session-takeover return code.
    # https://github.com/eclipse/mosquitto/commit/9d3f292
    if {[package vsatisfies $mosquitto 2.0.13-]} {testConstraint FIX9D3F292 1}
}

cd [testsDirectory]

set fd [open mosquitto.conf]
set lines [split [read $fd] \n]
close $fd

if {[lsearch -regexp $lines \
  {^(auth_)?plugin .*auth_plugin_extended_single.so}]} {
    testConstraint EXTAUTHS 1
}
if {[lsearch -regexp $lines \
  {^(auth_)?plugin .*auth_plugin_extended_multiple.so}]} {
    testConstraint EXTAUTHM 1
}

if {[file exists mosquitto.pid]} {
    set pid 0
} else {
    set pid [exec mosquitto -d -c mosquitto.conf 2>/dev/null &]
    # Give mosquitto a bit of time to start up
    sleep 100
}

proc echoclient {} {
    proc echoclient {} {}
    if {[testConstraint MQTTV5]} {
	mqtt create echo -protocol 5
	echo connect -properties {TopicAliasMaximum 40} echo
    } else {
	mqtt create echo -protocol 4
	echo connect echo
    }
    echo subscribe {tcltest/echo/#} [list reflect]
    echo subscribe {tcltest/var/#} [list message]
    update
}
    
proc reflect {topic data args} {
    regsub {^tcltest/echo/} $topic {} echo
    echo publish $echo $data
}

proc message {topic args} {
    tailcall sysmsg [lindex [split $topic /] 2] $topic {*}$args
}

proc sysmsg {varname topic data retain {props {}}} {
    upvar #0 $varname var
    set rc [dict create result message topic $topic data $data retain $retain]
    if {[llength $props]} {dict set rc properties $props}
    set var $rc
}

proc kill {} {
    global pid
    if {$pid && [file exists mosquitto.pid]} {
	set fd [open mosquitto.pid]
	set pid [read $fd]
	close $fd
	exec kill $pid
	# Allow time for the pid file to be removed
	sleep 100
    }
}
