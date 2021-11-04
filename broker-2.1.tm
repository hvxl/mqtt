# MQTT broker - 2017 Schelte Bron
# All normative statement references refer to the mqtt-v5.0-os document:
# https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.pdf

package require mqtt 3
package require sqlite3

proc mqtt::incrmsgid {num} {
    if {[incr num] & 0xffff} {return $num} else {return 1}
}

oo::define mqtt {
    method errorcode {str} {
	switch $str {
	    VERSION {return 132}
	    CLIENTID {return 133}
	}
    }
}

oo::define mqtt-v4 {
    method errorcode {str} {
	switch $str {
	    VERSION {return 1}
	    CLIENTID {return 2}
	}
    }
}

oo::class create broker {
    superclass mqtt
    constructor {db args} {
	variable workers {} timer {} publish {} config
	sqlite3 [namespace current]::db $db
	db function fit -deterministic ::mqtt::match
	db function incr -argcount 1 -deterministic ::mqtt::incrmsgid
	db transaction {
	    # The latest version of the database schema
	    set version 3.1
	    # Get an initial count of tables
	    set cnt [db onecolumn {select count(*) from sqlite_master}]
	    # Create a table for configuration settings
	    db eval {
		pragma foreign_keys = on;
		create table if not exists config (
		  name text primary key,
		  value text
		);
	    }
	    if {$cnt} {
		# Existing database, may be version 1
		set current 1
	    } else {
		# New database
		db eval {insert into config values ('version', $version)}
	    }
	    # Get the current version of the database schema
	    db eval {
		select value as current from config where name = 'version'
	    } {}
	    # Preparatory upgrade steps
	    if {[package vcompare $current 2a1] < 0} {
		db eval {
		    alter table "session" rename to "session_old";
		    alter table "filter" rename to "filter_old";
		    alter table "client" rename to "client_old";
		    alter table "state" rename to "state_old";
		}
	    }
	    db eval {
		create table if not exists message (
		  msguid integer primary key,
		  topic text,
		  content blob,
		  time int default (strftime('%s', 'now')),
		  flags int,	-- Extra bits: 4=retained, 5=will message
		  pending int default 0,
		  clientid int default 0
		);
		create table if not exists properties (
		  msguid int references message on delete cascade,
		  name text,
		  value blob
		);
		create table if not exists state (
		  clientid int,
		  msguid int references message on delete cascade,
		  qos int,
		  retain int default 0,	-- Depends on RAP
		  subids blob,		-- List of subscription IDs
		  identifier int,	-- Packet Identifier for QoS > 0
		  stage text default 'pending'
		);
		create table if not exists session (
		  clientid integer primary key,
		  msgid int default 0,	-- Last used packet identifier
		  interval int,		-- Session expiry interval
		  expire int,		-- Session expiry time
		  msguid int default 0,	-- Will message
		  delay int default 0 	-- Will Delay Interval
		);
		create table if not exists filter (
		  clientid int references client on delete cascade,
		  pattern text,
		  options int,
		  subid int default 0,
		  pool text,
		  primary key (clientid, pattern)
		);
		create table if not exists account (
		  username text primary key,
		  password text
		);
      		create table if not exists client (
		  clientid integer primary key,
		  client text unique,
		  allowed boolean default false
		);
		-- Triggers
		-- Make sure triggers will act recursively
		PRAGMA recursive_triggers = true;

		create trigger if not exists state_delete \
		  after delete on state when old.msguid <> 0
		begin
		  update message set pending = pending - 1 \
		    where message.msguid = old.msguid;
		end;
		create trigger if not exists state_insert \
		  after insert on state when new.msguid <> 0
		begin
		  update message set pending = pending + 1 \
		    where message.msguid = new.msguid;
		end;
		create trigger if not exists message_clean \
		  after update of pending, flags on message \
		  when new.pending = 0 and (new.flags & 0x10) = 0
		begin
		  delete from message where msguid = new.msguid;
		end;
		-- Reset the client ID on all messages when a session ends
		-- so retained messages will not be skipped for a new client
		-- that happens to get the recycled client ID assigned.
		-- Trigger this on the session table rather than the client
		-- table for consistency, as the client table entry may be
		-- kept when client based ACLs are in place.
		create trigger if not exists session_delete \
		  after delete on session
		begin
		  update message set clientid = 0 \
		    where clientid = old.clientid;
		  delete from filter where clientid = old.clientid;
		  delete from client \
		    where clientid = old.clientid and allowed = 0;
		end;
	    }

	    # Final upgrade steps
	    if {[package vcompare $current 2a1] < 0} {
		set current 2a1
		db eval {
		    -- Convert client_old to client
		    insert into client (client, allowed) \
		      select client, 1 from client_old;
		    drop table client_old;

		    -- Convert session_old to client and session
		    insert or ignore into client (client) \
		      select client from session_old;
		    insert into session (clientid) \
		      select c.clientid from session_old as s, client as c \
		      where c.client = s.client and s.clean = 0;
		    drop table session_old;

		    -- Convert entries from state_old to message and state
		    insert into message (topic, content, flags, clientid) \
		      select s.topic, s.content, s.qos << 1, c.clientid \
		      from state_old as s, client as c \
		      where s.client = c.client order by s.rowid;

		    insert into state (clientid, msguid, qos, stage) \
		      select c.clientid, m.msguid, s.qos, s.stage \
		      from state_old as s, client as c, message as m \
		      where m.topic = s.topic and c.client = s.client \
		      order by s.rowid;
		    drop table state_old;

		    -- Convert entries from retain to message
		    update message as m set flags = flags | 0x11 \
		      from (select topic from retain) as r \
		      where m.topic = r.topic;

		    insert or ignore into message (topic, content, flags) \
		      select topic, content, qos << 1 | 0x11 \
		      from retain;
		    drop table retain;

		    -- Convert filter_old to filter
		    insert into filter (clientid, pattern, options) \
		      select c.clientid, f.pattern, f.maxqos \
		      from filter_old as f, client as c \
		      where f.client = c.client;
		    drop table filter_old;

		    -- Track that the database structure has been upgraded to
		    -- the new version
		    replace into config values('version', $current);
		}
	    }
	    if {[package vcompare $current 3.1] < 0} {
		set current 3.1
		db eval {
		    alter table filter add column pool text;

		    -- Track that the database structure has been upgraded to
		    -- the new version
		    replace into config values('version', $current);
		}
	    }

	    # Clean up disconnected sessions
	    db eval {select clientid from session where expire is null} {
		my cleanup $clientid
	    }
	    db eval {select clientid from session where expire < $now} {
		my delete $clientid
	    }
	}

	next
	# Remove options that are not applicable for a broker
	set config [dict remove $config -username -password -clean]
	# Broker specific options
	dict set config -aliasmax 100
	my configure {*}$args
    }

    method listen {{port 1883}} {
	set workercmd [list apply [list {lport fd host rport} {
	    log "New connection from $host:$rport on port $lport."
	    coroutine $fd my worker $fd
	} [namespace current]] $port]
	set socketcmd [my configure -socketcmd]
	log "Opening listen socket on port $port."
	variable server [{*}$socketcmd -server $workercmd $port]
    }

    method workerconfig {} {
	my variable config
	dict filter $config key -keepalive -retransmit -aliasmax
    }

    method worker {fd} {
	set coro [info coroutine]
	set clientid 0
	set worker [worker new $fd [my workerconfig]]
	# trace add command $worker delete [list $coro destroyed]
	set retval [list $worker]
	set eval {}
	while 1 {
	    set args [lassign [yieldto my yieldproc $retval $eval] event]
	    set retval ""
	    set eval {}
	    switch -- $event {
		connect {
		    lassign $args client conn
		    set auth [my userauth $client $conn]
		    if {[dict get $auth retcode]} {
			set retval $auth
		    } else {
			set retval [my session $client $worker $conn]
			if {[dict get $conn client] eq ""} {
			    dict lappend retval prop \
			      AssignedClientIdentifier $client
			}
			dict lappend retval prop {*}[dict get $auth prop]
			set clientid [dict get $retval clientid]
			unset conn
		    }
		}
		auth {
		    lassign $args msg
		    set auth [my userauth $client $msg]
		    if {[info exists conn]} {
			set retval [my session $client $worker $conn]
			if {[dict get $conn client] eq ""} {
			    dict lappend retval prop \
			      AssignedClientIdentifier $client
			}
			dict lappend retval prop {*}[dict get $auth prop]
			set clientid [dict get $retval clientid]
			unset conn
		    } else {
			set retval $auth
		    }
		}
		subscribe {
		    set retval [my subscribe $clientid {*}$args]
		}
		unsubscribe {
		    set retval [my unsubscribe $clientid {*}$args]
		}
		notify {
		    my distribute $clientid {*}$args
		}
		stage {
		    lassign $args msgid stage
		    set recv [expr {$stage in {publish pubrel}}]
		    if {$stage eq "publish"} {
			db eval {
			    insert into state (clientid, identifier, stage) \
			      values ($clientid, $msgid, $stage)
			}
		    } elseif {$stage eq "pubrec"} {
			db eval {
			    update state set stage = $stage \
			      where clientid = $clientid \
			      and not ifnull(msguid, 0) = $recv \
			      and identifier = $msgid
			}
		    } else {
			db eval {
			    delete from state \
			      where clientid = $clientid \
			      and not ifnull(msguid, 0) = $recv \
			      and identifier = $msgid
			}
		    }
		}
		resume {
		    after idle [list [namespace which my] backlog $clientid]
		}
		disconnect {
		    lassign $args msg
		    if {![dict exists $msg reason] || \
		      [dict get $msg reason] == 0} {
			# Delete the will message
			my willmessage $clientid
		    }
		    if {[dict exists $msg prop SessionExpiryInterval]} {
			set interval [dict get $msg prop SessionExpiryInterval]
			db eval {
			    update session set interval = $interval \
			      where clientid = $clientid
			}
		    }
		    lappend eval [list $worker destroy]
		}
		destroyed {
		    break
		}
		terminate {
		    lassign $args reason
		    $worker disconnect $reason
		    break
		}
	    }
	}
	if {$clientid} {
	    my cleanup $clientid
	}
    }

    method clientid {name} {
	return \
	  [db onecolumn {select clientid from client where client = $name}]
    }

    method subscribe {clientid msg} {
	my variable publish
	dict with msg {}
	if {[dict exists $prop SubscriptionIdentifier]} {
	    set subid [dict get $prop SubscriptionIdentifier]
	} else {
	    set subid 0
	}
	set cnt 0
	set list {}
	db transaction {
	    dict for {pattern options} $topics {
		if {[string match {$share/*/*} $pattern]} {
		    # Shared subscription
		    set pattern [join [lassign [split $pattern /] - pool] /]
		    # No Retained Messages are sent on shared subscriptions
		    set rh 2
		} else {
		    unset -nocomplain pool
		    set rh [expr {$options >> 4 & 3}]
		}
		if {$rh == 1} {
		    # If Retain Handling is set to 1 then if the subscription
		    # did not already exist, the Server MUST send all retained
		    # message matching the Topic Filter of the subscription to
		    # the Client, and if the subscription did exist the Server
		    # MUST NOT send the retained messages. [MQTT-3.3.1-10].
		    db eval {
			select 2 as rh from filter \
			  where clientid = $clientid and pattern = $pattern
		    }
		}
		db eval {
		    replace into filter \
		      (clientid, pattern, options, subid, pool) \
		      values($clientid, $pattern, $options, $subid, $pool);
		}
		lappend list [expr {$options & 3}]
		if {$rh == 2} {
		    # If Retain Handling is set to 2, the Server MUST NOT send
		    # the retained messages [MQTT-3.3.1-11].
		} else {
		    # Send retained messages at the time of the subscribe
		    dict lappend publish $clientid \
		      [list $pattern $options $subid]
		    incr cnt
		}
	    }
	}
	if {$cnt} {
	    set cmd [list [namespace which my] retained]
	    after cancel $cmd
	    after idle $cmd
	}
	return $list
    }

    method propfilter {msg} {
	set prop {}
	foreach {name value} $prop {
	    switch $name {
		PayloadFormatIndicator -
		ContentType -
		ResponseTopic -
		CorrelationData -
		MessageExpiryInterval -
		UserProperty {
		    lappend prop $name $value
		}
	    }
	}
	return [dict set msg prop $prop]
    }

    method store {clientid msg {options {}}} {
	# Store a message in the database
	dict with msg {}
	set uid 0
	set mask 1
	set flags 0
	foreach flag {retain ack assure} {
	    if {$flag in $control} {set flags [expr {$flags | $mask}]}
	    incr mask $mask
	}
	foreach flag {retain will} {
	    incr mask $mask
	    if {$flag in $options} {set flags [expr {$flags | $mask}]}
	}
	db transaction {
	    if {"retain" in $options} {
		# If the RETAIN flag is set to 1 in a PUBLISH packet sent
		# by a Client to a Server, the Server MUST replace any
		# existing retained message for this topic and store the
		# Application Message [MQTT-3.3.1-5].
		db eval {
		    -- Switch of the retained message flag
		    -- Triggers will clean up if necessary
		    update message set flags = flags & ~0x10 \
		      where topic = $topic
		}
	    }
	    if {"retain" in $options && $message eq ""} {
		# If the Payload contains zero bytes it is processed
		# normally by the Server but any retained message with
		# the same topic name MUST be removed and any future
		# subscribers for the topic will not receive a retained
		# message [MQTT-3.3.1-6].
	    } else {
		db eval {
		    insert into message (topic, content, flags, clientid) \
		      values ($topic, $message, $flags, $clientid)
		}
		set uid [db last_insert_rowid]
		foreach {name value} $prop {
		    db eval {
			insert into properties (msguid, name, value) \
			  values ($uid, $name, $value)
		    }
		}
	    }
	}
	return $uid
    }

    method compose {msguid} {
	db eval {
	    select topic, content as message, flags \
	      from message where msguid = $msguid
	} rc {
	    set rc(prop) {}
	    db eval {select name, value from properties \
	      where msguid = $msguid} {
		switch $name {
		    MessageExpiryInterval {
			set value [expr {$time + $value - [clock seconds]}]
			# Bail out if the message has expired
			if {$value < 0} return
		    }
		}
		lappend rc(prop) $name $value
	    }
	    set rc(control) [my control [expr {$rc(flags) & 7}]]
	    unset rc(*)
	}
	return [array get rc]
    }

    method retained {} {
	my variable publish workers
	set send {}
	dict for {clientid records} $publish {
	    foreach n $records {
		lassign $n pattern options subid
		# Check the originating client if the no local option is set
		set id [expr {$options & 0b100 ? $clientid : -1}]
		db eval {
		    select msguid from message where (flags & 0x10) <> 0 \
		      and fit($pattern, topic) and clientid <> $id;
		} {
		    set qos [expr {$options & 3}]
		    dict update send $clientid client {
			dict lappend client $msguid [list $subid $qos]
		    }
		}
	    }
	}
	set publish {}
	if {[dict size $send] == 0} return
	dict for {clientid data} $send {
	    set prop {}
	    set maxqos 0
	    dict for {msguid matches} $data {
		set msg [my compose $msguid]
		if {[dict size $msg] == 0} continue
		dict with msg {}
		foreach match $matches {
		    lassign $match subid qos
		    if {$subid} {lappend prop SubscriptionIdentifier $subid}
		    if {$qos > $maxqos} {set maxqos $qos}
		}
		set instance [dict get $workers $clientid]
		if {[$instance configure -protocol] < 5} {
		    $instance publish $topic $message $qos 1
		} else {
		    $instance publish -properties $prop $topic $message $qos 1
		}
	    }
	}
    }

    method backlog {clientid} {
	my variable workers
	set instance [dict get $workers $clientid]
	db eval {
	    select * from state where clientid = $clientid order by rowid
	} {
	    switch $stage {
		pending {
		    # Pending and unack'd messages
		    set msg [my compose $msguid]
		    if {[dict size $msg] == 0} continue
		    dict with msg {}
		    if {[$instance configure -protocol] < 5} {
			$instance publish $topic $message $qos $retain
		    } else {
			$instance publish -properties $prop \
			  $topic $message $qos $retain
		    }
		}
		pubrec {
		    # No PUBCOMP received, resend the PUBREL
		    $instance reack $msgid 
		}
		publish {
		    # Expecting a PUBREL from the client
		    $instance expect $msgid
		}
	    }
	}
	db eval {delete from state where clientid = $clientid}
    }

    method unsubscribe {clientid topics} {
	db transaction {
	    set changes 0
	    dict for {pattern maxqos} $topics {
		db eval {
                    delete from filter \
		      where client = $clientid and pattern = $pattern
		}
		incr changes [db changes]
	    }
	}
	return $changes
    }

    method distribute {clientid msg} {
	my variable workers
	set msguid 0
	set topic [dict get $msg topic]
	# Remove all properties that should not be forwarded
	set msg [my propfilter $msg]
	# If the RETAIN flag is 0 in a PUBLISH packet sent by a Client to
	# a Server, the Server MUST NOT store the message as a retained
	# message and MUST NOT remove or replace any existing retained
	# message [MQTT-3.3.1-8].
	if {"retain" in [dict get $msg control]} {
	    set msguid [my store $clientid $msg retain]
	}
	set send {}
	set share {}
	db eval {
	    select f.options, f.clientid as id, f.subid, \
	      f.pool, (f.pool not null) as shared \
	      from filter as f, session as s \
	      where (f.options & 0x4 == 0 or f.clientid <> $clientid) \
	      and f.clientid = s.clientid and fit(f.pattern, $topic)
	} {
	    if {$shared} {
		dict update share $pool dict {
		    dict lappend dict $id [list $options $subid]
		}
	    } else {
		dict lappend send $id [list $options $subid]
	    }
	}
	# Pick a random client from each shared pool
	dict for {pool data} $share {
	    set rnd [expr {int(rand() * [dict size $data])}]
	    set id [lindex [dict keys $data] $rnd]
	    dict lappend send $id {*}[dict get $data $id]
	}
	if {[dict size $send] == 0} {
	    # No matching subscribers
	    return 16
	}
	db transaction {
	    set count 0
	    dict for {id records} $send {
		dict with msg {}
		set maxqos 0
		set retain 0
		set subids [lmap n $records {
		    lassign $n options subid
		    set subqos [expr {$options & 3}]
		    if {$options & 0x8} {set retain 1}
		    if {$subqos > $maxqos} {set maxqos $subqos}
		    if {$subid} {
			lappend prop SubscriptionIdentifier $subid
			set subid
		    } else {
			continue
		    }
		}]
		set q [expr {"ack" in $control | ("assure" in $control) << 1}]
		set qos [expr {min($q, $maxqos)}]
		if {$q} {
		    if {!$msguid} {
			set msguid [my store $clientid $msg pending]
		    }
		    if {0 && [dict exists $msg msgid]} {
			set msgid [dict get $msg msgid]
		    } else {
			db eval {
			    update session set msgid = incr(msgid) \
			      where clientid = $id;
			}
			set msgid [db onecolumn {
			    select msgid from session \
			      where clientid = $id;
			}]
		    }
		    db eval {
			insert into state \
			  (clientid, msguid, qos, retain, subids, identifier) \
			  values ($id, $msguid, $qos, $retain, $subids, $msgid)
		    }
		    incr count
		}
		if {[dict exists $workers $id]} {
		    set instance [dict get $workers $id]
		    if {[$instance configure -protocol] < 5} {
			$instance publish $topic $message $qos $retain
		    } else {
			$instance publish -properties \
			  $prop $topic $message $qos $retain
		    }
		}
	    }
	}
    }

    method cleanup {clientid} {
	my variable workers timer
	dict unset workers $clientid
	set now [clock seconds]
	db transaction {
	    db eval {
		update session set expire = $now + interval \
		  where clientid = $clientid;
	    }
	    db eval {
		select ifnull(interval, 0xffffffff) as keep, msguid, delay \
		  from session where clientid = $clientid
	    } {
		if {$keep > 0} {
		    set ms [expr {$keep * 1000}]
		    set my [namespace which my]
		    dict set timer $clientid delete [after $ms \
		      [list $my delete $clientid]]
		    if {$msguid} {
			if {$delay} {
			    set ms [expr {$delay * 1000}]
			    dict set timer $clientid will [after $ms \
			      [list $my willmessage $clientid $msguid]]
			} else {
			    my willmessage $clientid $msguid
			}
		    }
		} else {
		    my delete $clientid
		}
	    }
	}
    }

    method delete {clientid} {
	my variable timer
	# Cancel all timers
	if {[dict exists $timer $clientid]} {
	    dict for {name afterid} [dict get $timer $clientid] {
		after cancel $afterid
	    }
	    dict unset timer $clientid
	}
	db eval {select msguid from session \
	  where clientid = $clientid and msguid <> 0} {
	    my willmessage $clientid $msguid
	}
	db eval {delete from session where clientid = $clientid}
    }

    method willmessage {clientid {msguid 0}} {
	if {$msguid} {
	    # Send the will message to the interested parties
	    my distribute $clientid [my compose $msguid]
	}
	db eval {
	    delete from message where msguid = (
	      select msguid from session where clientid = $clientid
	    );
	    update session set msguid = 0 where clientid = $clientid;
	}
    }

    method yieldproc {retval {commands {}}} {
	foreach cmd $commands {{*}$cmd}
	return $retval
    }

    method userauth {name msg} {
	# Check username/password
	set user [if {[dict exists $msg username]} {dict get $msg username}]
	set pass [if {[dict exists $msg password]} {dict get $msg password}]
	set prop [if {[dict exists $msg prop]} {dict get $msg prop}]
	set retcode [catch {my authorize $name $user $pass $prop} retprop]
	if {$retcode == 1} {
	    set retcode 135
	    set retprop [list ReasonString $retprop]
	} elseif {$retcode == 4} {
	    set retcode 24
	}
	if {$retcode < 128} {
	    # If the initial CONNECT packet included an Authentication Method
	    # property then all AUTH packets, and any successful CONNACK
	    # packet MUST include an Authentication Method Property with the
	    # same value as in the CONNECT packet [MQTT-4.12.0-5].
	    if {[dict exists $prop AuthenticationMethod]} {
		if {![exists $retprop AuthenticationMethod]} {
		    dict lappend retprop \
		      AuthenticationMethod [dict get $prop AuthenticationMethod]
		}
	    }
	}
	return [dict create retcode $retcode prop $retprop]
    }

    method session {name worker msg} {
	my variable workers
	set rc [dict create session 0 retcode 0 prop {}]
	set prop {}
	set clean [dict get $msg clean]
	# If interval remains unset, the session does not expire.
	if {[dict exists $msg prop SessionExpiryInterval]} {
	    set keep [dict get $msg prop SessionExpiryInterval]
	    # If the interval is UINT_MAX, the session does not expire.
	    if {$keep != 0xffffffff} {set interval $keep}
	} elseif {$clean} {
	    # The Session ends when the Network Connection is closed.
	    set interval 0
	}

	db transaction {
	    set clientid [my clientid $name]
	    if {$clientid ne ""} {
		# Known client
		if {[dict exists $workers $clientid]} {
		    # An active session exists - terminate it
		    # 142: Session taken over
		    [dict get $workers $clientid] disconnect 142
		}
		if {$clean} {
		    # A clean start instantly terminates the old session
		    my cleanup $clientid
		    my delete $clientid
		    set clientid ""
		} else {
		    # Resuming an existing session
		    my variable timer
		    # Cancel all timers
		    if {[dict exists $timer $clientid]} {
			dict for {n afterid} [dict get $timer $clientid] {
			    after cancel $afterid
			}
			dict unset timer $clientid
		    }
		    set now [clock seconds]
		    db eval {
			select 1 from session \
			  where clientid = $clientid \
			  and ifnull(expire >= $now, 1)
		    } {
			dict set rc session 1
		    }
		    # Specs are unclear. Should the old will message be kept?
		    # For now, remove it
		    my willmessage $clientid
		}
	    }
	    if {$clientid eq ""} {
		# Create a new id
		db eval {insert into client (client) values ($name)}
		set clientid [db last_insert_rowid]
	    }
	    dict set workers $clientid $worker
	    if {[dict get $rc session]} {
		db eval {
		    update session \
		      set interval = $interval, msguid = 0, delay = 0 \
		      where clientid = $clientid
		}
	    } else {
		db eval {
		    insert into session (clientid, interval, msguid, delay) \
		      values ($clientid, $interval, 0, 0);
		}
	    }
	    if {[dict exists $msg will]} {
		if {[dict exists $msg will prop WillDelayInterval]} {
		    set willdelay [dict get $msg will prop WillDelayInterval]
		    db eval {
			update session set delay = $willdelay \
			  where clientid = $clientid
		    }
		}
		set will [my store $clientid \
		  [my propfilter [dict get $msg will]] will]
		db eval {
		    update session set msguid = $will where clientid = $clientid
		}
	    }
	}
	# Provide the actual client ID back to the caller
	dict set rc clientid $clientid
	# Connection Accepted
	return [dict set rc prop $prop]
    }

    method takeover {clientid} {
	my variable workers timer
	if {[dict exists $workers clientid]} {
	    # Session taken over
	    [dict get $workers clientid] terminate 142
	} else {
	    # Terminate an existing suspended session
	    my cleanup $clientid
	}
	my delete $clientid
    }

    method authorize {client user password prop} {
	if {[dict exists $prop AuthenticationMethod]} {
	    # 140: Bad authentication method
	    return -code 140
	}
	if {[db onecolumn {select count(*) from client where allowed = 1}]} {
	    if {![db exists {select 1 from client \
	      where client = $client and allowed = 1}]} {
		# Allowed client ids configured, but client isn't one of them
		return -code 135
	    }
	}
	if {[db onecolumn {select count(*) from account}] == 0} {
	    if {[db exists {select 1 from account \
	      where username = $user and ifnull(password = $password, 1)}]} {
		# Accounts configured, but user isn't one of them
		return -code 135
	    }
	}
	# Client is authorized
	return
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

    unexport authentication authorize backlog cleanup clientid
    unexport compose connect decode delete disconnect distribute errorcode
    unexport propfilter publish reauthenticate retained session store
    unexport subscribe takeover unsubscribe userauth will willmessage
    unexport worker workerconfig yieldproc
}

oo::class create mqtt::worker {
    superclass mqtt

    constructor {sock opts} {
	next
	variable clientid "" fd $sock broker [info coroutine] keepalive 0
	variable config $opts aliasmax [dict get $opts -aliasmax]
	oo::objdefine [self] mixin mqtt::helper
	coroutine $fd my client
    }

    destructor {
	my variable timer fd coro broker
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
	# Inform the broker this worker is finished
	$broker destroyed
    }

    method client {} {
	my variable fd queue clientid broker aliasmax
	variable coro [info coroutine]
	fconfigure $fd -blocking 0 -buffering none -translation binary
	fileevent $fd readable [list $coro receive $fd]
	set rc 0
	set event [my receive $fd]
	# After a Network Connection is established by a Client to a
	# Server, the first packet sent from the Client to the Server
	# MUST be a CONNECT packet [MQTT-3.1.0-1].
	if {[lindex $event 0] eq "CONNECT"} {
	    set rc [my handle $event]
	} else {
	    set rc 130
	}
	# Run the auth loop until the connection is established
	while {$rc == 24 && $fd ne "" && ![eof $fd]} {
	    set event [my receive $fd]
	    switch [lindex $event 0] {
		AUTH {
		    set msg [lindex $event 1]
		    set resp [$broker auth $msg]
		    set rc [dict get $resp retcode]
		    if {$rc == 24} {
			my message $fd AUTH resp
		    } else {
			dict lappend resp prop TopicAliasMaximum $aliasmax
			my message $fd CONNACK resp
		    }
		    if {$rc == 0 && [dict get $resp session]} {
			# Resume session
			$broker resume
		    }
		}
		DISCONNECT {
		    set rc [my handle $event]
		}
		default {
		    # If a Client sets an Authentication Method in the
		    # CONNECT, the Client MUST NOT send any packets other
		    # than AUTH or DISCONNECT packets until it has received
		    # a CONNACK packet [MQTT-3.1.2-30].
		    set rc 130
		}
	    }
	}
	# Run the main loop as long as the connection is up
	while {!$rc && $fd ne "" && ![eof $fd]} {
	    # Send out any queued messages
	    set queue [foreach n $queue {
		lassign $n type msg
		my message $fd $type msg
	    }]
	    set eventlist {}
            # Due to bug https://core.tcl.tk/tcl/tktview/6141c15186, all
	    # pending data must be handled before sending out notifications
	    while 1 {
		lappend eventlist [my receive $fd]
		if {[chan pending input $fd] == 0} break
	    }
	    foreach event $eventlist {
		if {[lindex $event 0] in {CONNECT}} {
		    # The Server MUST process a second CONNECT packet sent
		    # from a Client as a Protocol Error and close the
		    # Network Connection [MQTT-3.1.0-2].
		    set rc 130
		} else {
		    set rc [my handle $event]
		}
		if {$rc} break
	    }
	}
	if {$clientid ne ""} {
	    log "Client $clientid disconnected"
	} else {
	    log "Client disconnected"
	}
	if {$fd ne ""} {
	    my close $rc
	    my destroy
	}
    }

    method reack {msgid} {
	my variable pending fd
	set msg [dict create msgid $msgid reason 0 prop {}]
	set pending($type,PUBREL) [dict create msg $msg count 0]
	my message $fd PUBREL msg
    }

    method expect {msgid} {
	my variable pending
	set msg [dict create msgid $msgid reason 0 prop {}]
	set pending($type,PUBREC) [dict create msg $msg count 0]
	set ms [my configure -retransmit]
	set cmd [list [namespace which my] retransmit PUBREL $msgid]
	my timer $msgid $ms $cmd
    }
}

# Helper class that needs to be at the front of the search path so it
# can override methods inplemented in the MQTT version specific class.
oo::class create mqtt::helper {
    method report {dir type dict} {
	my variable clientid
	if {$clientid ne ""} {lappend dir $clientid}
	next $dir $type $dict
    }

    method disconnect {args} {
	my variable config
	if {[dict get $config -protocol] < 5} {
	    # Before v5, only a client could send a DISCONNECT message
	    my finish
	} else {
	    next {*}$args
	}
    }

    method connection {flags} {
	payload Su keepalive
	my properties
	my string client
	if {$flags & 0b100} {
	    my properties will
	    my string {will topic}
	    my string {will message}
	    set qos [expr {$flags >> 3 & 0b11}]
	    set ctrl [expr {$flags >> 5 & 0b1 | $qos << 1}]
	    set will [dict create control [my control $ctrl] prop {}]
	} else {
	    set will {}
	}
	if {$flags & 0b10000000} {my string username}
	if {$flags & 0b01000000} {my string password}
	return $will
    }

    method clientname {msg} {
	# Check client identifier
	variable clientid [dict get $msg client]
	if {$clientid eq ""} {
	    # Assign a client ID
	    set clientid auto-[expr {round(rand() * 10e8) + [info cmdcount]}]
	}
	return $clientid
    }

    method decode {type control msg size} {
	switch -- $type {
	    CONNECT {
		my variable config
		my string protocol
		set ver [payload cu version]
		lassign [payload cu] flags
		if {$ver >= 3 && $ver <= 5} {
		    # Mix in the specifics for the selected version
		    oo::objdefine [self] mixin -append mqtt-v$ver
		    dict set config -protocol $ver
		    set will [my connection $flags]
		    set rc [payload]
		}
		dict set rc clean [expr {($flags & 0b10) != 0}]
		if {$flags & 0b100} {
		    dict set rc will [dict merge $will [dict get $rc will]]
		}
		my clientname $rc
		return $rc
	    }
	    SUBSCRIBE {
		payload Su msgid
		set pos 2
		incr pos [my properties]
		while {$pos < $size} {
		    try {my string} on ok {topic opts} {
			incr pos [dict get $opts -count]
		    }
		    payload cu [list topics $topic]
		    incr pos
		}
	    }
	    UNSUBSCRIBE {
		payload Su msgid
		set pos 2
		incr pos [my properties]
		while {$pos < $size} {
		    try {my string} on ok {topic opts} {
			incr pos [dict get $opts -count]
		    }
		    payload a0 [list topics $topic]
		}
	    }
	    PINGREQ {}
	    default {
		return [next $type $control $msg $size]
	    }
	}
	return [payload]
    }

    method process {event {msg {}}} {
	my variable fd broker config clientid
	switch -- $event {
	    CONNECT {
		set protocol [dict get $msg protocol]
		set version [dict get $msg version]
		if {$version >= 4 && $version <= 5 && $protocol eq "MQTT" \
		  || $version == 3 && $protocol eq "MQIsdp"} {
		    my variable limits aliasmax
		    variable topicalias {}
		    dict for {key val} $limits {
			if {[dict exists $msg prop $key]} {
			    dict set limits $key [dict get $msg prop $key]
			}
		    }
		    set rc [$broker connect $clientid $msg]
		} else {
		    # Connection Refused, unacceptable protocol version
		    set retcode [my errorcode VERSION]
		    set rc [dict create session 0 retcode $retcode prop {}]
		}
		set code [dict get $rc retcode]
		if {$code == 24} {
		    my message $fd AUTH $rc
		} else {
		    dict lappend rc prop TopicAliasMaximum $aliasmax
		    my message $fd CONNACK rc
		    if {$code} {
			# If a server sends a CONNACK packet containing a
			# non-zero return code it MUST then close the
			# Network Connection [MQTT-3.2.2-6].
			tailcall my close
		    }
		    if {[dict get $rc session]} {
			# Resume session
			$broker resume
		    }
		}
	    }
	    AUTH {
		set rc [$broker auth $msg]
		set code [dict get $rc retcode]
		if {$code < 128} {
		    my message $fd AUTH $rc
		} else {
		    # Re-authentication failed
		    my disconnect $code
		}
	    }
	    PUBLISH - PUBACK - PUBREC - PUBREL - PUBCOMP {
		dict lappend msg prop
		set rc [next $event $msg]
		if {$rc} {
		    if {$event eq "PUBLISH"} {
			if {"assure" ni [dict get $msg control]} return
		    }
		    $broker stage [dict get $msg msgid] [string tolower $event]
		}
	    }
	    SUBSCRIBE {
		dict lappend msg prop
		set msgid [dict get $msg msgid]
		set list [$broker subscribe $msg]
		set rc [dict create msgid $msgid results $list]
		my message $fd SUBACK rc
	    }
	    UNSUBSCRIBE {
		set msgid [dict get $msg msgid]
		set reason [$broker unsubscribe $msg]
		set rc [dict create msgid $msgid reason $reason]
		my message $fd UNSUBACK rc
	    }
	    PINGREQ {
		my message $fd PINGRESP
	    }
	    DISCONNECT {
		$broker disconnect $msg
	    }
	    CONNACK - SUBACK - UNSUBACK - PINGRESP {
		# The client should not be sending these messages
		throw {MQTT MESSAGE UNEXPECTED} "unexpected message: $event"
	    }
	}
    }

    method notify {msg} {
	my variable broker
	$broker notify $msg
    }

    method CONNACK {msgvar} {
	upvar 1 $msgvar msg
	set msg [dict merge {session 0 retcode 0} $msg {control {}}]
	set data [binary format cc \
	  [dict get $msg session] [dict get $msg retcode]]
	append data [my props connack msg]
	return $data
    }

    method SUBACK {msgvar} {
	upvar 1 $msgvar msg
	dict set msg control {}
	set data [my seqnum msg]
	append data [my props suback msg]
	append data [binary format c* [dict get $msg results]]
	return $data
    }

    method UNSUBACK {msgvar} {
	upvar 1 $msgvar msg
	dict set msg control {}
	return [my seqnum msg][my props unsuback msg]
    }

    method PINGRESP {msgvar} {
	upvar 1 $msgvar msg
	set msg {control {}}
	return
    }

    method notifier {} {}
}

oo::objdefine broker {forward log ::mqtt::logpfx}

# source [file join [file dirname [info script]] brokerdebug.tcl]
