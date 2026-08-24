package tui

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"

foreign import terminal_libc "system:c"

foreign terminal_libc {
	@(link_name = "ioctl")
	terminal_ioctl :: proc(fd: c.int, request: c.ulong, size: ^Window_Size) -> c.int ---
}

Window_Size :: struct {
	rows:    u16,
	columns: u16,
	xpixel:  u16,
	ypixel:  u16,
}

when ODIN_OS == .Darwin {
	TERMINAL_SIZE_REQUEST :: 0x40087468
} else {
	TERMINAL_SIZE_REQUEST :: 0x5413
}

resize_pending: bool
exit_pending: bool

terminal_signal_handler :: proc "c" (signal: posix.Signal) {
	if signal == posix.Signal(posix.SIGWINCH) {
		resize_pending = true
	} else if signal == .SIGINT || signal == .SIGTERM {
		exit_pending = true
	}
}

terminal_install_signal_handlers :: proc() -> bool {
	action := posix.sigaction_t{sa_handler = terminal_signal_handler, sa_flags = {.RESTART}}
	_ = posix.sigemptyset(&action.sa_mask)
	return posix.sigaction(posix.Signal(posix.SIGWINCH), &action, nil) == .OK &&
	       posix.sigaction(.SIGINT, &action, nil) == .OK &&
	       posix.sigaction(.SIGTERM, &action, nil) == .OK
}

terminal_take_resize :: proc() -> bool {
	value := resize_pending
	resize_pending = false
	return value
}

terminal_should_exit :: proc() -> bool {
	return exit_pending
}

terminal_size :: proc() -> (width, height: int, ok: bool) {
	size: Window_Size
	if terminal_ioctl(c.int(posix.STDOUT_FILENO), c.ulong(TERMINAL_SIZE_REQUEST), &size) != 0 ||
	   size.columns == 0 || size.rows == 0 {
		return 0, 0, false
	}
	return int(size.columns), int(size.rows), true
}

Terminal :: struct {
	saved:  posix.termios,
	active: bool,
}

Terminal_Input_State :: enum {
	Timeout,
	Data,
	Closed,
	Failed,
}

panic_terminal: ^Terminal

terminal_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	if panic_terminal != nil do terminal_restore(panic_terminal)
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

terminal_arm_panic_restore :: proc(terminal: ^Terminal) -> runtime.Assertion_Failure_Proc {
	previous := context.assertion_failure_proc
	panic_terminal = terminal
	context.assertion_failure_proc = terminal_assertion_failure
	return previous
}

terminal_disarm_panic_restore :: proc(previous: runtime.Assertion_Failure_Proc) {
	context.assertion_failure_proc = previous
	panic_terminal = nil
}

terminal_enter :: proc(terminal: ^Terminal) -> bool {
	if terminal.active || !posix.isatty(posix.STDIN_FILENO) || !posix.isatty(posix.STDOUT_FILENO) {
		return false
	}
	if posix.tcgetattr(posix.STDIN_FILENO, &terminal.saved) != .OK {
		return false
	}
	raw := terminal.saved
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_cflag += {.CS8}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw) != .OK {
		return false
	}
	terminal.active = true
	_, err := os.write_string(os.stdout, "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?2004h")
	return err == nil
}

terminal_read :: proc(input: []byte, timeout_ms := 100) -> (int, Terminal_Input_State) {
	descriptor := posix.pollfd{
		fd = posix.STDIN_FILENO,
		events = {.IN},
	}
	ready := posix.poll(&descriptor, 1, c.int(timeout_ms))
	if ready == 0 do return 0, .Timeout
	if ready < 0 {
		if posix.get_errno() == .EINTR do return 0, .Timeout
		return 0, .Failed
	}
	if descriptor.revents >= {.NVAL} || descriptor.revents >= {.ERR} {
		return 0, .Failed
	}
	if descriptor.revents >= {.HUP} && !(descriptor.revents >= {.IN}) {
		return 0, .Closed
	}
	count, err := os.read(os.stdin, input)
	if err != nil || count == 0 do return 0, .Closed
	return count, .Data
}

terminal_restore :: proc(terminal: ^Terminal) {
	if !terminal.active {
		return
	}
	_, _ = os.write_string(os.stdout, "\x1b[0m\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?25h\x1b[?1049l")
	_ = posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &terminal.saved)
	terminal.active = false
}

terminal_cursor :: proc(visible: bool, x := 0, y := 0) {
	if !visible {
		_, _ = os.write_string(os.stdout, "\x1b[?25l")
		return
	}
	sequence := fmt.aprintf("\x1b[%d;%dH\x1b[?25h", y + 1, x + 1)
	defer delete(sequence)
	_, _ = os.write_string(os.stdout, sequence)
}
