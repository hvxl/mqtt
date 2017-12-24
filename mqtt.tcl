# MQTT Utilities - 2017 Schelte Bron
# Small library of routines for mqtt comms.
# Based on code by Mark Lawson
# BTW, some of this stuff only makes sense if you have the MQTT spec handy.

package require Tcl 8.6

namespace eval mqtt {
    proc log {str} {
	# Override if logging is desired
    }
}

oo::class create mqtt {
    constructor {args} {
	namespace path [linsert [namespace path] end ::mqtt]
	variable config {
	    -keepalive		60
	    -retransmit		5000
	    -username		""
	    -password		""
	    -clean		1
	    -protocol		4
	}
	variable fd "" data "" queue {} connect {} coro ""
	variable keepalive [expr {[dict get $config -keepalive] * 1000}]
	variable subscriptions "" seqnum 0

	# Message types
	variable msgtype {
	    {}		CONNECT		CONNACK		PUBLISH
	    PUBACK	PUBREC		PUBREL		PUBCOMP
	    SUBSCRIBE	SUBACK	    	UNSUBSCRIBE	UNSUBACK
	    PINGREQ	PINGRESP	DISCONNECT	{}
	}

	my configure {*}$args
    }

    destructor {
	my disconnect
    }

    method report {dir type dict} {
	set str "[string totitle $dir] $type"
	set arglist {}
	switch -- $type {
	    CONNECT {
		foreach n {clean keepalive username} {
		    if {[dict exists $dict $n]} {
			lappend arglist [string index $n 0][dict get $dict $n]
		    }
		}
	    }
	    CONNACK {
		foreach n {session retcode} {
		    if {[dict exists $dict $n]} {
			lappend arglist [dict get $dict $n]
		    }
		}
	    }
	    PUBLISH {
		set flags [dict get $dict flags]
		set tmp [dict create dup 0 qos 0 retain 0]
		if {[dict exists $dict msgid]} {
		    dict set tmp msgid [dict get $dict msgid]
		}
		if {"retain" in $flags} {dict incr tmp retain}
		if {"ack" in $flags} {dict incr tmp qos}
		if {"assure" in $flags} {dict incr tmp qos 2}
		if {"dup" in $flags} {dict incr tmp dup}
		foreach n {dup qos retain msgid} {
		    if {[dict exists $tmp $n]} {
			lappend arglist [string index $n 0][dict get $tmp $n]
		    }
		}
		lappend arglist '[dict get $dict topic]'
		lappend arglist "...\
		  ([string length [dict get $dict data]] bytes)"
	    }
	    PUBREC - PUBREL - PUBACK {
		lappend arglist "Mid: [dict get $dict msgid]"
	    }
	    SUBSCRIBE - UNSUBSCRIBE {
		dict for {topic qos} [dict get $dict topics] {
		    append str \n "    $topic (QoS $qos)"
		}
	    }
	    SUBACK {
		foreach n [dict get $dict results] {
		    if {$n < 128} {
			lappend arglist "QoS $n"
		    } else {
			lappend arglist "Failure"
		    }
		}
	    }
	    default {
		set args {}
	    }
	}
	if {[llength $arglist]} {
	    append str " ([join $arglist {, }])"
	}
	log $str
    }

    method protocol {} {
	my variable config
	return [dict get $config -protocol]
    }

    method configure {args} {
	my variable config
	if {[llength $args] == 0} {
	    return [lsort -index 0 -stride 2 $config]
	} elseif {[llength $args] == 1} {
	    set arg [lindex $args 0]
	    if {![dict exist $config $arg]} {
		set args [dict keys $config $arg*]
		if {[llength $args] != 1} {
		    error [format {unknown or ambiguous option: "%s"} $arg]
		}
		set arg [lindex $args 0]
	    }
	    return [dict get $config $arg]
	} elseif {[llength $args] % 2 == 0} {
	    foreach {opt val} $args {
		if {![dict exist $config $opt]} {
		    set opts [dict keys $config $opt*]
		    if {[llength $opts] != 1} {
			error [format {unknown or ambiguous option: "%s"} $opt]
		    }
		    set opt [lindex $opts 0]
		}
		switch -- $opt {
		    -keepalive {
			if {$val < 0 || $val > 65535} {
			    error "keepalive must be between 0 and 65535"
			}
			variable keepalive [expr {$val * 1000}]
		    }
		    -retransmit {
			if {$val < 0 || $val > 3600000} {
			    error "retransmit must be between 0 and 3600000"
			}
		    }
		    -clean {
			set val [expr {![string is false -strict $val]}]
		    }
		    -protocol {
			if {$val ni {3 4}} {
			    error "only protocol levels 3 (3.1)\
			      and 4 (3.1.1) are currently supported"
			}
		    }
		}
		dict set config $opt $val
	    }
	}
    }

    method connect {name {host localhost} {port 1883}} {
	my variable coro config
	if {$coro ne ""} {error "illegal request"}
	set level [my protocol]
	if {$level == 4} {
	    if {$name eq "" && ![dict get $config -clean]} {
		error "a zero-length client identifier is not allowed\
		  when the -clean option is set to false"
	    }
	} elseif {$level == 3} {
	    if {$name eq "" || [string length $name] > 23} {
		error [format {invalid client identifier: "%s"} $name]
	    }
	}
	coroutine [self object]_coro my client $name $host $port
    }

    method disconnect {} {
	my variable fd timer coro
	my message DISCONNECT
	foreach n [array names timer] {
	    after cancel $timer($n)
	}
	if {$coro ne ""} {
	    set coro [$coro destroy]
	}
	if {$fd ne ""} {
	    catch {close $fd}
	    set fd ""
	}
    }

    # Allow yield resumption with multiple arguments
    method yieldm {{value ""}} {
	yieldto return -level 0 $value
    }

    method timer {name time {cmd ""}} {
	my variable timer
	if {[info exists timer($name)]} {
	    after cancel $timer($name)
	    unset timer($name)
	}
	if {$time eq "expire"} {
	    if {[catch {uplevel #0 $cmd} result]} {
		log $result
	    }
	} elseif {$time ne "cancel"} {
	    # Route timer expiry back through this method to clean up the array
	    set timer($name) \
	      [after $time [list [namespace which my] timer $name expire $cmd]]
	    return $name
	}
    }

    # Convert a string to utf8
    method bin {str} {
	set bytes [encoding convertto utf-8 $str]
	return [binary format Sa* [string length $bytes] $bytes]
    }

    # Convert from utf8 to a string
    method str {str} {
	return [encoding convertfrom utf8 $str]
    }

    method will {topic {message ""} {qos 1} {retain 0}} {
	my variable connect
	if {$topic eq ""} {
	    dict unset connect will
	} else {
	    dict set connect will [dict create \
	      topic $topic message $message qos $qos retain $retain]
	}
	return
    }

    method client {name host port} {
	my variable fd queue config connect subscriptions pending
	variable coro [info coroutine]

	dict set connect client $name
	dict set connect keepalive [dict get $config -keepalive]
	dict set connect clean [dict get $config -clean]
	if {[dict get $config -username] ne ""} {
	    dict set connect username [dict get $config -username]
	    if {[dict get $config -password] ne ""} {
		dict set connect password [dict get $config -password]
	    }
	}

	set retry 0
	while {1} {
	    try {
		if {[my init $host $port]} {
		    set ms [clock milliseconds]
		    if {[dict get $config -clean]} {
			# Reinstate subscriptions
			foreach pat [dict keys $subscriptions] {
			    set msg [dict create topics [dict create $pat 2]]
			    my message SUBSCRIBE $msg
			}
		    }
		    while {$fd ne "" && ![eof $fd]} {
			foreach n $queue {
			    my message {*}$n
			}
			set queue ""
			my listen
		    }
		    set sleep 0
		    # If the connection was established but lost again very
		    # quickly, we were possibly stealing the connection from
		    # another client with the same name, who took it back
		    if {[clock milliseconds] < $ms + 1000} {
			if {$retry <= 0} {
			    set sleep 30000
			} else {
			    incr retry -1
			}
		    } else {
			set retry 3
		    }
		} else {
		    set sleep 10000
		}
	    } trap {MQTT CONNECTION REFUSED} {result opts} {
		log "Connection refused, $result"
		# This is a fatal error, no need to retry
		break
	    } on error {err info} {
		# Something unexpected went wrong. Try to recover.
		puts "[clock milliseconds] ($coro): [dict get $info -errorinfo]"
		# Prevent looping too fast
		set sleep 10000
	    } finally {
		if {$fd ne ""} {
		    # Stop keepalive messages
		    my timer ping cancel
		    catch {close $fd}
		    set fd ""
		}
		# Cancel all retransmits
		foreach n [array names pending] {
		    my timer [dict get $pending($n) msg msgid] cancel
		    unset pending($n)
		}
	    }
	    if {$sleep > 0} {my sleep $sleep}
	}
    }

    method sleep {time} {
	my variable coro
	my timer sleep $time [list $coro wake]
	while {[my listen] ne "wake"} {}
    }

    method init {host port} {
	my variable fd coro
	if {$fd ne ""} {
	    log "Warning: Init called ($host:$port) while fd = $fd"
	    return 0
	}
	log "Connecting to $host on port $port"
	if {[catch {socket -async $host $port} sock]} {
	    log "Connection failed: $sock"
	    return 0
	}
	my timer init 10000 [list $coro noanswer $sock]
	fileevent $sock writable [list $coro connect $sock]
	# Queue events are allowed to happen during initialization
	try {
	    while {[my listen $sock] in {queue transmit}} {}
	} finally {
	    # Cancel the timer even if [my listen] fails, while allowing
	    # the error to continue to percolate up the call stack
	    my timer init cancel
	}
	if {$fd ne $sock} {
	    close $sock
	    return 0
	}
	# Expect a CONNACK in a reasonable time
	my variable config
	my timer connack [dict get $config -retransmit] [list $coro noanswer]
	try {
	    while {[set event [my listen $sock CONNACK]] \
	      in {partial queue transmit}} {}
	} finally {
	    my timer connack cancel
	}
	return [expr {$event eq {connack}}]
    }

    method listen {{sock ""} {expect {}}} {
	my variable coro fd queue connect pending
	if {$fd ne "" && ![eof $fd]} {
	    fileevent $fd readable [list $coro receive $fd]
	}
	set args [lassign [my yieldm] event]
	switch -- $event {
	    noanswer {
		log "Connection timed out"
	    }
	    connect {
		set sock [lindex $args 0]
		set error [fconfigure $sock -error]
		fileevent $sock writable {}
		if {$error eq ""} {
		    set fd $sock
		    fconfigure $fd \
		      -blocking 0 -buffering none -translation binary
		    my message CONNECT $connect
		} else {
		    log "Connection failed: $error"
		}
	    }
	    receive {
		set msg [my receive $expect]
		if {[dict size $msg] == 0} {
		    if {[eof $fd]} {
			log "encountered EOF on $fd"
			fileevent $fd readable {}
			set event eof
		    } else {
			set event partial
		    }
		} elseif {[dict exists $msg retcode]} {
		    switch -- [dict get $msg retcode] {
			0 {# Connection Accepted
			    set event connack
			}
			1 {
			    throw {MQTT CONNECTION REFUSED PROTOCOL} \
			      "unacceptable protocol version"
			}
			2 {
			    throw {MQTT CONNECTION REFUSED IDENTIFIER} \
			      "identifier rejected"
			}
			3 {
			    throw {MQTT CONNECTION REFUSED SERVER} \
			      "server unavailable"
			}
			4 {
			    throw {MQTT CONNECTION REFUSED LOGIN} \
			      "bad user name or password"
			}
			5 {
			    throw {MQTT CONNECTION REFUSED AUTH} \
			      "not authorized"
			}
		    }
		}
	    }
	    queue {
		lappend queue $args
	    }
	    transmit {
		my message {*}$args
	    }
	    keepalive {
		my message PINGREQ
	    }
	    retransmit {
		lassign $args type msgid
		if {[info exists pending($type,$msgid)]} {
		    set msg [dict get $pending($type,$msgid) msg]
		    if {"dup" ni [dict get $msg flags]} {
			dict lappend msg flags dup
		    }
		    # Retransmit the message
		    my message $type $msg
		}
	    }
	    destroy {
		if {$sock ne ""} {close $sock}
		if {$fd ne ""} {set fd [close $fd]}
		# Exit all the way out of the coroutine
		return -level [info level]
	    }
	}
	return $event
    }

    method ack {type msgid} {
	variable pending
	if {[info exists pending($type,$msgid)]} {
	    my timer $msgid cancel
	    unset pending($type,$msgid)
	}
    }

    method receive {{expect {}}} {
	my variable fd data msgtype store
	if {[string length $data] < 1} {append data [read $fd 1]}
	if {[binary scan $data cu hdr] < 1} return
	for {set len 0; set ptr 1; set shift 0} {$ptr < 5} {incr shift 7} {
	    if {[string length $data] <= $ptr} {append data [read $fd 1]}
	    if {[binary scan [string index $data $ptr] cu l] != 1} return
	    set len [expr {$len + (($l & 0x7f) << $shift)}]
	    incr ptr
	    if {$l < 128} break
	}
	append data [read $fd $len]
	if {[string length $data] < $ptr + $len} return

	set type [lindex $msgtype [expr {$hdr >> 4}]]
	set payload [string range $data $ptr end]
	set rc [dict create type $type flags {} payload $payload]
	set mask 1
	foreach n {retain ack assure dup} {
	    if {$hdr & $mask} {dict lappend rc flags $n}
	    incr mask $mask
	}
	set data ""
	if {[llength $expect] && $type ni $expect} {
	    return $rc
	}
	switch -- $type {
	    CONNACK {
		binary scan $payload cucu session retcode
		dict set rc session $session
		dict set rc retcode $retcode
	    }
	    PUBLISH {
		binary scan $payload Su topiclen
		if {"assure" in [dict get $rc flags]} {
		    # Decode the message
		    set fmt [format x2a%dSua* $topiclen]
		    binary scan $payload $fmt topic msgid content
		    dict set rc msgid $msgid
		    # Store the data
		    set store($msgid) [list $topic $content]
		    # Indicate reception of the PUBLISH message
		    my message PUBREC [dict create msgid $msgid]
		} elseif {"ack" in [dict get $rc flags]} {
		    # Decode the message
		    set fmt [format x2a%dSua* $topiclen]
		    binary scan $payload $fmt topic msgid content
		    dict set rc msgid $msgid
		    # Distribute the content to all subscribers
		    my distribute $topic $content
		    # Indicate reception of the PUBLISH message
		    my message PUBACK [dict create msgid $msgid]
		} else {
		    set fmt [format x2a%da* $topiclen]
		    binary scan $payload $fmt topic content
		    # Distribute the content to all subscribers
		    my distribute $topic $content
		}
		dict set rc topic $topic
		dict set rc data $content
	    }
	    PUBACK {
		if {[binary scan $payload Su msgid] == 1} {
		    dict set rc msgid $msgid
		    my ack PUBLISH $msgid
		}
	    }
	    PUBREC {
		if {[binary scan $payload Su msgid] == 1} {
		    dict set rc msgid $msgid
		    my ack PUBLISH $msgid
		    my message PUBREL [dict create msgid $msgid]
		}
	    }
	    PUBREL {
		if {[binary scan $payload Su msgid] == 1} {
		    dict set rc msgid $msgid
		    my ack PUBREC [dict create msgid $msgid]
		    if {[info exists store($msgid)]} {
			my distribute {*}$store($msgid)
			unset store($msgid)
		    }
		    my message PUBCOMP [dict create msgid $msgid]
		}
	    }
	    PUBCOMP {
		if {[binary scan $payload Su msgid] == 1} {
		    dict set rc msgid $msgid
		    my ack PUBREL $msgid
		}
	    }
	    SUBACK {
		if {[binary scan $payload Sucu* msgid codes] == 2} {
		    dict set rc msgid $msgid
		    dict set rc results $codes
		    my ack SUBSCRIBE $msgid
		}
	    }
	    UNSUBACK {
		if {[binary scan $payload Su msgid] == 1} {
		    dict set rc msgid $msgid
		    my ack UNSUBSCRIBE $msgid
		}
	    }
	}
	my report received $type $rc
	return $rc
    }

    method match {pattern topic} {
	foreach p [split $pattern /] n [split $topic /] {
	    if {$p eq "#"} {
		return 1
	    } elseif {$p ne $n && $p ne "+"} {
		return 0
	    }
	}
	return 1
    }

    method distribute {topic data} {
	my variable subscriptions
	dict for {pat cmds} $subscriptions {
	    if {[my match $pat $topic]} {
		foreach n $cmds {
		    after idle [linsert $n end $topic $data]
		}
	    }
	}
    }

    method message {type {msg {}}} {
	my variable msgtype fd pending coro config keepalive
	# Can only send a message when connected
	if {$fd eq ""} {return 0}

	my report sending $type $msg

	# Build the payload depending on the message type
	dict set msg payload [set payload [my $type msg]]

	# Build the header byte
	set hdr [expr {[lsearch -exact $msgtype $type] << 4}]
	set flags [dict get $msg flags]
	if {"dup" in $flags} {set hdr [expr {$hdr | 0b1000}]}
	if {"ack" in $flags} {set hdr [expr {$hdr | 0b010}]}
	if {"assure" in $flags} {set hdr [expr {$hdr | 0b100}]}
	if {"retain" in $flags} {set hdr [expr {$hdr | 0b1}]}

	# Calculate the data length
	set ll {}
	set len [string length $payload]
	while {$len > 127} {
	    lappend ll [expr {$len & 0x7f | 0x80}]
	    set len [expr {$len >> 7}]
	}
	lappend ll $len

	if {"ack" in $flags || "assure" in $flags} {
	    set msgid [dict get $msg msgid]
	    dict set pending($type,$msgid) msg $msg
	    set ms [dict get $config -retransmit]
	    set cmd [list $coro retransmit $type $msgid]
	    dict set pending($type,$msgid) id [my timer $msgid $ms $cmd]
	    dict incr pending($type,$msgid) count
	}

	# Restart the keep-alive timer
	if {$keepalive > 0} {
	    my timer ping $keepalive [list $coro keepalive]
	}

	# Send the message
	set data [binary format cc*a* $hdr $ll $payload]
	if {[catch {puts -nonewline $fd $data}]} {
	    return 0
	} else {
	    return 1
	}
    }

    method subscribe {pattern prefix} {
	my variable subscriptions coro
	if {![dict exists $subscriptions $pattern]} {
	    set msg [dict create topics [dict create $pattern 2]]
	    $coro transmit SUBSCRIBE $msg
	}
	dict lappend subscriptions $pattern $prefix
	return
    }

    method unsubscribe {pattern prefix} {
	my variable subscriptions coro
	if {[dict exists $subscriptions $pattern]} {
	    dict update subscriptions $pattern pat {
		set pat [lsearch -all -inline -exact -not $pat $prefix]
		if {[llength $pat] == 0} {
		    unset pat
		    set msg [dict create topics [dict create $pattern 2]]
		    $coro transmit UNSUBSCRIBE $msg
		}
	    }
	}
    }

    method publish {topic message {qos 1} {retain 0}} {
	my variable coro

	set flags [lindex {{} ack assure} $qos]
	if {$retain} {lappend flags retain}
	set msg [dict create topic $topic data $message flags $flags]
	$coro queue PUBLISH $msg
    }

    method seqnum {msgvar} {
	upvar 1 $msgvar msg
	my variable seqnum
	if {[dict exists $msg msgid]} {
	    set msgid [dict get $msg msgid]
	} else {
	    if {([incr seqnum] & 0xffff) == 0} {set seqnum 1}
	    set msgid $seqnum
	    dict set msg msgid $msgid
	}
	return [binary format S $msgid]
    }

    method CONNECT {msgvar} {
	upvar 1 $msgvar msg

	# The DUP, QoS, and RETAIN flags are not used in the CONNECT message.
	dict set msg flags {}

	# Create the payload
	set flags 0
	if {[dict exists $msg clean] && [dict get $msg clean]} {
	    set flags 0b10
	}
	# Client Identifier
	set payload [my bin [dict get $msg client]]
	if {[dict exists $msg will topic]} {
	    set flags [expr {$flags | 0b100}]
	    append payload [my bin [dict get $msg will topic]]
	    if {[dict exists $msg will message]} {
		append payload [my bin [dict get $msg will message]]
	    } else {
		append payload [my bin ""]
	    }
	    if {[dict exists $msg will qos]} {
		set flags [expr {$flags | ([dict get $msg will qos] << 3)}]
	    }
	    if {[dict exists $msg will retain] && [dict get $msg will retain]} {
		set flags [expr {$flags | 0b100000}]
	    }
	}
	if {[dict exists $msg username]} {
	    set flags [expr {$flags | 0b10000000}]
	    append payload [my bin [dict get $msg username]]
	    if {[dict exists $msg password]} {
		set flags [expr {$flags | 0b1000000}]
		append payload [my bin [dict get $msg password]]
	    }
	}
	set level [my protocol]
	if {$level < 4} {
	    set data [my bin MQIsdp]
	} else {
	    set data [my bin MQTT]
	}
	append data [binary format ccS $level $flags [dict get $msg keepalive]]
	append data $payload
	return $data
    }

    method CONNACK {msgvar} {
	upvar 1 $msgvar msg
	set msg [dict merge {retcode 0} $msg {flags {}}]
	return [binary format cc 0 [dict get $msg retcode]]
    }

    method PUBLISH {msgvar} {
	upvar 1 $msgvar msg
	set msg [dict merge {flags {} data ""} $msg]
	set data [my bin [dict get $msg topic]]
	set flags [dict get $msg flags]
	if {"ack" in $flags || "assure" in $flags} {
	    append data [my seqnum msg]
	}
	append data [dict get $msg data]
	return $data
    }

    method PUBACK {msgvar} {
	upvar 1 $msgvar msg
	dict set msg flags {}
	return [my seqnum msg]
    }

    method PUBREC {msgvar} {
	upvar 1 $msgvar msg
	dict set msg flags {}
	return [my seqnum msg]
    }

    method PUBREL {msgvar} {
	upvar 1 $msgvar msg
	set msg [dict merge {flags {}} $msg]
	set flags [lsearch -all -inline -exact [dict get $msg flags] dup]
	dict set msg flags [lappend flags ack]
	return [my seqnum msg]
    }

    method PUBCOMP {msgvar} {
	upvar 1 $msgvar msg
	dict set msg flags {}
	return [binary format S [dict get $msg msgid]]
    }

    method SUBSCRIBE {msgvar} {
	upvar 1 $msgvar msg
	set msg [dict merge {flags {} topics {}} $msg]
	set flags [lsearch -all -inline -exact [dict get $msg flags] dup]
	dict set msg flags [lappend flags ack]
	set data [my seqnum msg]
	dict for {topic qos} [dict get $msg topics] {
	    append data [my bin $topic]
	    append data [binary format c $qos]
	}
	return $data
    }

    method SUBACK {msgvar} {
	upvar 1 $msgvar msg
	dict set msg flags {}
	set data [my seqnum msg]
	dict for {topic qos} [dict get $msg topics] {
	    append data [binary format c $qos]
	}
	return $data
    }

    method UNSUBSCRIBE {msgvar} {
	upvar 1 $msgvar msg
	set msg [dict merge {flags {} topics {}} $msg]
	set flags [lsearch -all -inline -exact [dict get $msg flags] dup]
	dict set msg flags [lappend flags ack]
	set data [my seqnum msg]
	dict for {topic qos} [dict get $msg topics] {
	    append data [my bin $topic]
	}
	return $data
    }

    method UNSUBACK {msgvar} {
	upvar 1 $msgvar msg
	dict set msg flags {}
	return [my seqnum msg]
    }

    method PINGREQ {msgvar} {
	upvar 1 $msgvar msg
	set msg {flags {}}
	return
    }

    method PINGRESP {msgvar} {
	upvar 1 $msgvar msg
	set msg {flags {}}
	return
    }

    method DISCONNECT {msgvar} {
	upvar 1 $msgvar msg
	set msg {flags {}}
	return
    }

    unexport ack bin client distribute init listen match message protocol
    unexport receive report seqnum sleep str timer yieldm
}

oo::objdefine mqtt {forward log proc ::mqtt::log}
