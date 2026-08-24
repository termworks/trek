package main

import "core:fmt"
import "core:os"

VERSION :: "0.1.0"

greeting :: proc() -> string {
	return "hello from trek"
}

usage :: proc() {
	fmt.println("trek")
	fmt.println("")
	fmt.println("Usage:")
	fmt.println("  trek [--help] [--version]")
}

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		if args[0] == "-h" || args[0] == "--help" {
			usage()
			return
		}
		if args[0] == "-V" || args[0] == "--version" {
			fmt.println(VERSION)
			return
		}
	}
	fmt.println(greeting())
}
