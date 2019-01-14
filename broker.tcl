# MQTT broker - 2017 Schelte Bron

package require mqtt 2-
package require sqlite3

oo::class create broker {
    superclass mqtt
    constructor {db args} {
	variable workers {} config
	sqlite3 [namespace current]::db $db
	db eval {
	    pragma foreign_keys = on;
	    create table if not exists retain (
	      topic text primary key,
	      content blob,
	      qos int
	    );
	    create table if not exists session (
              client text primary key,
	      clean int,
	      time int
            );
	    create table if not exists filter (
	      client text references session on delete cascade,
	      pattern text,
	      maxqos int,
	      primary key (client, pattern)
	    );
	    -- create index filterindex on filter(client);
	    create table if not exists state (
	      client text,
	      topic text,
	      content blob,
	      qos int,
	      stage text
	    );
	    create table if not exists account (
	      username text primary key,
	      password text
	    );
	    create table if not exists client (
	      client text primary key
	    );
	    delete from session where clean = 1;
	}
	db function fit -deterministic ::mqtt::match
	next
	# Remove options that are not applicable for a broker
	set config [dict remove $config -username -password -clean]
	my configure {*}$args
    }

    method listen {{port 1883}} {
	set workercmd [list apply [list {lport fd host rport} {
	    log "New connection from $host on port $lport"
	    coroutine $fd my worker $fd
	} [namespace current]] $port]
	set socketcmd [my configure -socketcmd]
	log "Opening listen socket on port $port."
	variable server [{*}$socketcmd -server $workercmd $port]
    }

    method worker {fd} {
	my variable workers
	set coro [info coroutine]
	set will {}
	set worker [worker new $fd]
	trace add command $worker delete [list $coro destroyed]
	set retval [list $worker]
	while 1 {
	    set args [lassign [yieldto list {*}$retval] event]
	    set retval ""
	    switch -- $event {
		clientid {
		    lassign $args msg
		    set retval [my session $worker $msg]
		    if {$retval > 0} {
			# After returning the CONNACK, close the connection
			after idle [list $coro terminate]
		    } else {
			set clientid [dict get $msg client]
			if {[dict exists $msg will]} {
			    set will [dict get $msg will]
			}
		    }
		}
		subscribe {
		    set retval [my subscribe $clientid {*}$args]
		}
		unsubscribe {
		    my unsubscribe $clientid {*}$args
		}
		notify {
		    my distribute $clientid {*}$args
		}
		disconnect {
		    # MQTT-3.14.4-3: On receipt of DISCONNECT the Server
		    # MUST discard any Will Message associated with the
		    # current connection without publishing it.
		    set will {}
		    break
		}
		destroyed {
		    after cancel [list $coro terminate]
		    break
		}
		terminate {
		    break
		}
	    }
	}
	if {[info exists clientid]} {
	    my cleanup $clientid $worker
	    if {[dict exists $will topic]} {
		set message ""
		set qos 1
		set retain 0
		dict with will {
		    my distribute $clientid $topic $message $qos $retain
		}
	    }
	}
    }

    method subscribe {clientid topics} {
	set list {}
	db transaction {
	    dict for {pattern maxqos} $topics {
		db eval {
		    replace into filter (client, pattern, maxqos) \
		      values($clientid, $pattern, $maxqos);
		}
		lappend list $maxqos
	    }
	}
	after idle [list [namespace which my] retained $clientid $topics]
	return $list
    }

    method retained {client topics} {
	my variable workers
	set send {}
	dict for {pattern maxqos} $topics {
	    db eval {
		select topic, content, qos from retain \
		  where fit($pattern, topic);
	    } {
		if {$qos > $maxqos} {set qos $maxqos}
		if {[dict exists $send $topic qos]} {
		    set qos [expr {max($qos, [dict get $send $topic qos])}]
		}
		dict set send $topic [dict create data $content qos $qos]
	    }
	}
	if {[dict size $send] == 0} return
	# MQTT-3.3.1-6 / MQTT-3.3.1-8
	set instance [dict get $workers $client]
	dict for {topic dict} $send {
	    $instance publish \
	      $topic [dict get $dict data] [dict get $dict qos] 1
	}
    }

    method backlog {client} {
	my variable workers
	set instance [dict get $workers $client]
	db eval {select * from state where client = $client} {
	    $instance publish $topic $content $qos
	}
	db eval {delete from state where client = $client}
    }

    method unsubscribe {clientid topics} {
	db transaction {
	    dict for {pattern maxqos} $topics {
		db eval {
                    delete from filter \
		      where client = $clientid and pattern = $pattern
		}
	    }
	}
    }

    method distribute {origin topic data qos retain} {
	my variable workers
	db transaction {
	    db eval {
		select f.client, max(f.maxqos) as maxqos, s.clean \
		  from filter as f, session as s \
		  where f.client != $origin \
		  and fit(f.pattern, $topic) \
		  and s.client = f.client \
		  group by f.client;
	    } {
		if {[dict exists $workers $client]} {
		    set instance [dict get $workers $client]
		    $instance publish $topic $data $qos 0
		} elseif {!$clean && $qos > 0} {
		    db eval {
			insert into state \
			  (client, topic, content, qos, stage) \
			  values ($client, $topic, $data, $qos, 'pending');
		    }
		}
	    }
	    # MQTT-3.3.1-12
	    if {$retain} {
		if {[string length $data] > 0} {
		    # MQTT-3.3.1-5
		    db eval {
			replace into retain (topic, content, qos) \
			  values($topic, $data, $qos);
		    }
		} else {
		    # MQTT-3.3.1-10 / MQTT-3.3.1-11
		    db eval {
			delete from retain where topic = $topic;
		    }
		}
	    }
	}
    }

    method cleanup {name worker} {
	my variable workers
	if {[dict get $workers $name] ne $worker} return
	db eval {
	    delete from session where client = $name and clean = 1;
	    update session set time = strftime('%s','now') \
	      where client = $name;
	}
	dict unset workers $name
    }

    method session {worker msg} {
	my variable workers
	set protocol [dict get $msg protocol]
	set version [dict get $msg version]
	if {$version == 4 && $protocol eq "MQTT"} {
	} elseif {$version == 3 && $protocol eq "MQIsdp"} {
	} else {
	    # Connection Refused, unacceptable protocol version
 	    return 1
	}

	try {
	    # Check client identifier
	    set name [dict get $msg client]
	    if {![my identify $name]} {return 2}

	    # Check username/password
	    set auth [dict values [dict filter $msg key username password]]
	    if {![my authenticate {*}$auth]} {return 5}
	} on error err {
	    # The identify and authenticate methods may be overridden by the
	    # application. In case they produce an error, refuse all
	    # connections with code 3: Server unavailable.
	    log "Error: $err"
	    return 3
	}

	if {[dict exists $workers $name]} {
	    [dict get $workers $name] destroy
	}
	dict set workers $name $worker
	set clean [dict get $msg clean]
	set sp 0
	db transaction {
	    if {$clean} {
		db eval {
		    delete from filter where client = $name;
		    delete from state where client = $name;
		}
	    } else {
		db eval {select -1 as sp from session where client = $name} {}
		if {$sp} {
		    after idle [list [namespace which my] backlog $name]
		    if {$version < 4} {set sp 0}
		}
	    }
	    db eval {
		replace into session (client, clean) values ($name, $clean);
	    }
	}
	# Connection Accepted
	return $sp
    }

    method identify {name} {
	if {[db onecolumn {select count(*) from client}] == 0} {
	    # No client ids configured, allow all
	    return 1
	}
	return [db exists {select 1 from client where client = $name}]
    }

    method authenticate {args} {
	if {[db onecolumn {select count(*) from account}] == 0} {
	    # No usernames configured, allow everyone
	    return 1
	}
	lassign $args name pass
	if {[db exists {select 1 from account \
	  where username = $name and password = $pass}]} {
	    return 1
	}
	if {[db exists {select 1 from account \
	  where username = $name and password is null}]} {
	    return 1
	}
	return 0
    }

    method useradd {user {passwd ""}} {
	if {[llength [info level 0]] > 3} {set pass $passwd}
	db eval {
	    replace into account (username, password) values ($user, $pass)
	}
	return
    }

    method userdel {user} {
	db eval {delete from account where username = $user}
	return
    }

    method clientadd {name} {
	db eval {insert or ignore into client (client) values ($name)}
	return
    }

    method clientdel {name} {
	db eval {delete from client where client = $name}
	return
    }

    unexport connect disconnect publish subscribe unsubscribe will
    unexport worker distribute cleanup identify authenticate session
}

oo::class create mqtt::worker {
    superclass mqtt

    constructor {sock} {
	variable clientid ""
	next
	variable fd $sock broker [info coroutine] keepalive 0
	fconfigure $fd -blocking 0 -translation binary
	coroutine $fd my client $fd
    }

    destructor {
	my variable timer fd coro
	foreach n [array names timer] {
	    after cancel $timer($n)
	}
	if {$coro ne ""} {
	    if {$coro ne [info coroutine]} {
		set coro [$coro destroy]
	    }
	    my notifier
	}
	my close
    }

    method report {dir type dict} {
	my variable clientid
	if {$clientid ne ""} {lappend dir $clientid}
	next $dir $type $dict
    }

    method client {fd} {
	my variable queue clientid
	variable coro [info coroutine]
	fconfigure $fd -blocking 0 -buffering none -translation binary
	fileevent $fd readable [list $coro receive $fd]
	# Run the main loop as long as the connection is up
	while {$fd ne "" && ![eof $fd]} {
	    # Send out any queued messages
	    set queue [foreach n $queue {my message $fd {*}$n}]
	    set eventlist {}
            # Due to bug https://core.tcl.tk/tcl/tktview/6141c15186, all
	    # pending data must be handled before sending out notifications
	    while 1 {
		lappend eventlist [my receive $fd]
		if {[chan pending input $fd] == 0} break
	    }
	    foreach event $eventlist {
		my process {*}$event
	    }
	}
	if {$clientid ne ""} {
	    log "Client $clientid disconnected"
	} else {
	    log "Client disconnected"
	}
	my close
	my destroy
    }

    method process {event args} {
	my variable fd broker
	switch -- $event {
	    CONNECT {
		lassign $args msg
		set retval [$broker clientid $msg]
		variable clientid [dict get $msg client]
		set rc [dict create session 0 retcode 0]
		if {$retval > 0} {
		    dict set rc retcode $retval
		} else {
		    dict set rc session [expr {$retval != 0}]
		}
		my message $fd CONNACK $rc
	    }
	    PUBLISH - PUBACK - PUBREC - PUBREL - PUBCOMP {
		next $event {*}$args
	    }
	    SUBSCRIBE {
		lassign $args msg
		set msgid [dict get $msg msgid]
		set list [$broker subscribe [dict get $msg topics]]
		my message $fd SUBACK [dict create msgid $msgid results $list]
	    }
	    UNSUBSCRIBE {
		lassign $args msg
		set msgid [dict get $msg msgid]
		$broker unsubscribe [dict get $msg topics]
		my message $fd UNSUBACK [dict create msgid $msgid]
	    }
	    PINGREQ {
		my message $fd PINGRESP
	    }
	    DISCONNECT {
		$broker disconnect
	    }
	    CONNACK - SUBACK - UNSUBACK - PINGRESP {
		# The client should not be sending these messages
		throw {MQTT MESSAGE UNEXPECTED} "unexpected message: $event"
	    }
	}
    }

    method notify {msg} {
	my variable broker
	dict with msg {
	    set qos 0
	    foreach {flag q} {assure 2 ack 1} {
		if {$flag in $control} {set qos $q; break}
	    }
	    $broker notify $topic $data $qos [expr {"retain" in $control}]
	}
    }

    method notifier {} {}
}

oo::objdefine broker {forward log ::mqtt::logpfx}
