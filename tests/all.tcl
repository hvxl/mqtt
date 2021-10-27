package require Tcl 8.6
package require tcltest 2.5

namespace import tcltest::*

if 0 {
    trace add execution runAllTests enterstep [list apply [list {cmd op} {
	puts $cmd
    }]]
}

configure -testdir [file dirname [file normalize [info script]]] {*}$argv
runAllTests
