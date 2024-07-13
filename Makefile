DTPLITE_PROG    = /usr/bin/dtplite
DTPLITE         = $(DTPLITE_PROG)

srcdir = "$(PWD)"
PKG_ENV = TCL8_6_TM_PATH="$(srcdir)" TCL9_0_TM_PATH="$(srcdir)"
TCLSH_PROG = /usr/bin/tclsh8.6
TCLSH = $(PKG_ENV) $(TCLSH_ENV) $(TCLSH_PROG)

mqtt.n: mqtt.man
	$(DTPLITE) -o $@ nroff $+ $>

mqtt.html: mqtt.man
	$(DTPLITE) -o $@ html $+ $>

broker.n: broker.man
	$(DTPLITE) -o $@ nroff $+ $>

broker.html: broker.man
	$(DTPLITE) -o $@ html $+ $>

test:
	$(TCLSH) `echo $(srcdir)/tests/all.tcl` $(TESTFLAGS)

# Include a local make file, if it exists
-include Makefile-local.mk
