import os
import os.cmdline
import net
import time
import math
import rand
import term
import term.ui as tui
import sokol.audio

const version = '0.1'
const padding = 2

const black = '\x1b[30m'
const red = '\x1b[31m'
const green = '\x1b[32m'
const yellow = '\x1b[33m'
const blue = '\x1b[34m'
const magenta = '\x1b[35m'
const cyan = '\x1b[36m'
const white = '\x1b[37m'

const bg_black = '\x1b[40m'
const bg_red = '\x1b[41m'
const bg_green = '\x1b[42m'
const bg_yellow = '\x1b[43m'
const bg_blue = '\x1b[44m'
const bg_magenta = '\x1b[45m'
const bg_cyan = '\x1b[46m'
const bg_white = '\x1b[47m'

const reset = '\x1b[0m'
const bold = '\x1b[1m'
const fg_reset = '\x1b[39m'
const bg_reset = '\x1b[49m'

const bright_black = '\x1b[90m'
const bright_red = '\x1b[91m'
const bright_green = '\x1b[92m'
const bright_yellow = '\x1b[93m'
const bright_blue = '\x1b[94m'
const bright_magenta = '\x1b[95m'
const bright_cyan = '\x1b[96m'
const bright_white = '\x1b[97m'

const bg_bright_black = '\x1b[100m'
const bg_bright_red = '\x1b[101m'
const bg_bright_green = '\x1b[102m'
const bg_bright_yellow = '\x1b[103m'
const bg_bright_blue = '\x1b[104m'
const bg_bright_magenta = '\x1b[105m'
const bg_bright_cyan = '\x1b[106m'
const bg_bright_white = '\x1b[107m'

pub struct Packet {
pub mut:
	length   int
	id       int
	buffer   []u8
	position int
}

pub fn Packet.new(buf []u8) Packet {
	return Packet{
		buffer: buf
	}
}

pub fn (mut p Packet) decode() {
	p.length = p.read_varint()
	p.id = p.read_varint()
}

pub fn (mut p Packet) encode() {
	mut old_buf := p.buffer.clone()
	p.buffer = []u8{}
	p.write_varint(old_buf.len)
	p.buffer << old_buf
}

pub fn (mut p Packet) write_varint(num int) {
	mut value := num
	mut bytes := []u8{}
	mut index := 0
	for {
		b := u8(value & 0x7F)
		index++
		value >>= 7
		if value != 0 {
			bytes << (b | 0x80)
		} else {
			bytes << b
			break
		}
	}
	p.buffer << bytes
}

pub fn (mut p Packet) read_varint() int {
	mut value := 0
	mut shift := 0
	mut index := 0
	for {
		b := p.buffer[p.position + index]
		index++
		value |= u32(b & 0x7F) << shift
		shift += 7
		if (b & 0x80) == 0 {
			break
		}
	}
	p.position += index
	return value
}

pub fn (mut p Packet) write_string(str string) {
	p.write_varint(str.len)
	p.buffer << str.bytes()
}

pub fn (mut p Packet) read_string() string {
	str_len := p.read_varint()
	str := p.buffer[p.position..p.position + str_len]
	p.position += str_len
	mut result := ''
	for byt in str {
		result += byt.ascii_str()
	}
	return result
}

pub fn (mut p Packet) read_short() u16 {
	short_bytes := p.buffer[p.position..p.position + 2]
	short := u16(short_bytes[0]) << 8 | u16(short_bytes[1])
	p.position += 2
	return short
}

pub fn (mut p Packet) write_long(num i64) {
	mut value := num
	mut bytes := []u8{}
	for _ in 0 .. 8 {
		bytes << u8(value & 0xFF)
		value >>= 8
	}
	p.buffer << bytes
}

pub fn (mut p Packet) read_long() i64 {
	mut value := i64(0)
	for i in 0 .. 8 {
		value |= u64(p.buffer[p.position + i]) << (i * 8)
	}
	p.position += 8
	return value
}

struct ClientMessage implements Message {
mut:
	content string
}

struct ChatMessage implements Message {
mut:
	owner         int
	owner_name    string
	id            string
	date          time.Time
	content       string
	edited        bool
	deleted       bool
	delete_reason string
	reply         string
	is_preview    bool
}

fn (mut msg ChatMessage) clone() ChatMessage {
	return ChatMessage{
		owner:         msg.owner
		owner_name:    msg.owner_name
		id:            msg.id
		date:          msg.date
		content:       msg.content
		edited:        msg.edited
		deleted:       msg.deleted
		delete_reason: msg.delete_reason
		reply:         msg.reply
		is_preview:    msg.is_preview
	}
}

const gray_rgb = '\x1b[38;2;128;128;128m'

fn (mut msg ChatMessage) format() string {
	mut result := ''

	if msg.is_preview {
		result += '> '
	} else if msg.reply != '' {
		result += '  '
	}

	result += white + msg.owner_name + fg_reset + ': '

	if msg.deleted {
		if msg.delete_reason == '' {
			result += '${red}<deleted>${fg_reset}'
		} else {
			result += '${red}<deleted: ${cyan}${msg.delete_reason}${red}>${fg_reset}'
		}
	} else {
		result += msg.content

		if msg.edited {
			result += ' ${gray_rgb}(edited)${fg_reset}'
		}
	}

	return result
}

interface Message {
mut:
	content string
}

struct Client {
mut:
	conn         &net.TcpConn = unsafe { nil }
	tui          &tui.Context = unsafe { nil }
	debug        bool
	nick         string
	cursor       int
	input        string
	messages     []Message
	id           int
	users        map[int]string
	focused      int = -1
	max_messages int
	offset       int

	editing  string
	deleting string
	replying string

	original_message string

	width  int
	height int

	flakes     []Snowflake
	snow       bool
	snow_timer int

	playing    int = -1
	play_timer int

	sw          time.StopWatch
	sw_start_ms time.Duration

	reset_audio bool

	frame int
}

pub fn (mut cl Client) send_login(nick string) {
	mut login_packet := Packet{}
	login_packet.write_varint(0)
	login_packet.write_string(nick.trim_space())
	login_packet.encode()
	time.sleep(24 * time.millisecond)
	cl.conn.write(login_packet.buffer) or {}
}

pub fn (mut cl Client) send_message(message string) {
	mut message_packet := Packet{}
	message_packet.write_varint(1)
	message_packet.write_string(message.trim_space())
	message_packet.encode()
	time.sleep(24 * time.millisecond)
	cl.conn.write(message_packet.buffer) or {}
}

pub fn (mut cl Client) delete_message(message_id string, reason string) {
	mut delete_packet := Packet{}
	delete_packet.write_varint(2)
	delete_packet.write_string(message_id)
	delete_packet.write_string(reason.trim_space())
	delete_packet.encode()
	time.sleep(24 * time.millisecond)
	cl.conn.write(delete_packet.buffer) or {}
}

pub fn (mut cl Client) edit_message(message_id string, new_message string) {
	mut edit_packet := Packet{}
	edit_packet.write_varint(3)
	edit_packet.write_string(message_id)
	edit_packet.write_string(new_message.trim_space())
	edit_packet.encode()
	time.sleep(24 * time.millisecond)
	cl.conn.write(edit_packet.buffer) or {}
}

pub fn (mut cl Client) reply_message(message_id string, reply string) {
	mut reply_packet := Packet{}
	reply_packet.write_varint(4)
	reply_packet.write_string(message_id)
	reply_packet.write_string(reply.trim_space())
	reply_packet.encode()
	time.sleep(24 * time.millisecond)
	cl.conn.write(reply_packet.buffer) or {}
}

pub fn (mut cl Client) send_command(command string) {
	mut command_packet := Packet{}
	command_packet.write_varint(5)
	command_packet.write_string(command.trim_space())
	command_packet.encode()
	time.sleep(24 * time.millisecond)
	cl.conn.write(command_packet.buffer) or {}
}

pub fn (mut cl Client) get_nick() string {
	return cl.users[cl.id]
}

pub fn (mut cl Client) listen() {
	mut buf := []u8{len: 1024}

	for {
		read := cl.conn.read(mut buf) or { continue }
		data := buf[..read].clone()
		if data.len == 0 {
			continue
		}

		mut packet := Packet.new(data)
		packet.decode()

		if packet.id == 0 { // info
			cl.id = packet.read_varint()
			cl.client_msg('[client] User ID is ${cl.id}.')
		} else if packet.id == 1 { // introduce
			id := packet.read_varint()
			cl.users[id] = packet.read_string()
		} else if packet.id == 2 { // chat message
			owner_id := packet.read_varint()
			message_id := packet.read_string()
			timestamp := packet.read_string()
			message := packet.read_string()
			reply := packet.read_string()

			date := time.unix(timestamp.i64()).local()

			mut msg := ChatMessage{
				owner:      owner_id
				owner_name: cl.users[owner_id]
				id:         message_id
				date:       date
				content:    message
				reply:      reply
			}

			cl.chat_msg(msg)
		} else if packet.id == 3 { // system message
			cl.client_msg('[system] ' + packet.read_string())
		} else if packet.id == 4 { // delete message
			message_id := packet.read_string()
			reason := packet.read_string()

			for mut msg in cl.messages {
				if mut msg is ChatMessage {
					if msg.id == message_id {
						msg.edited = false
						msg.deleted = true
						msg.delete_reason = reason
					}
				}
			}
		} else if packet.id == 5 { // edit message
			message_id := packet.read_string()
			new_message := packet.read_string()

			for mut msg in cl.messages {
				if mut msg is ChatMessage {
					if msg.id == message_id {
						msg.content = new_message
						msg.edited = true
					}
				}
			}
		} else if packet.id == 6 { // event packet
			event_id := packet.read_varint()

			if event_id == 0 { // clear chat
				cl.messages.clear()
			} else if event_id == 1 { // snow
				cl.snow = true
			} else if event_id == 2 { // bytebeat
				cl.play_audio(1)
			}
		}
	}
}

struct Snowflake {
mut:
	x          int
	y          int
	delay      int
	cycle_left int
}

pub fn (mut cl Client) update_snowflakes() {
	mut flake_count := 0

	for mut flake in cl.flakes {
		if flake.cycle_left > 0 {
			if flake.delay > 0 {
				flake.delay--
			} else {
				flake.y += 1
			}

			if flake.y >= cl.height {
				flake.x = rand.int_in_range(0, cl.width) or { 0 }
				flake.y = 0
				flake.delay = rand.int_in_range(0, 12) or { 0 }
				flake.cycle_left -= 1
			}

			if flake.cycle_left > 0 {
				flake_count++
			}
		}
	}

	if flake_count == 0 {
		cl.snow = false
		cl.flakes = []Snowflake{}
	}
}

pub fn (mut cl Client) draw_snowflakes() {
	for flake in cl.flakes {
		if flake.cycle_left > 0 && flake.delay == 0 {
			if flake.y < cl.height && flake.x < cl.width {
				cl.tui.draw_text(flake.x, flake.y, '*')
			}
		}
	}
}

pub fn (mut cl Client) play_audio(id int) {
	cl.play_timer = 0
	cl.playing = id
}

pub fn (mut cl Client) bytebeat(mut soundbuffer &f32, num_frames int, num_channels int) {
	for frame := 0; frame < num_frames; frame++ {
		t := i32(f32(cl.frame + frame) * 0.245)
		y := (t * (((t / 10 | 0) ^ ((t / 10 | 0) - 1280)) % 11) / 2 & 127) +
			(t * (((t / 640 | 0) ^ ((t / 640 | 0) - 2)) % 13) / 2 & 127)
		for ch := 0; ch < num_channels; ch++ {
			idx := frame * num_channels + ch
			a := f32(y - 127) / 255.0
			soundbuffer[idx] = a
		}
	}
	cl.frame += num_frames
}

@[inline]
fn sintone(periods int, frame int, num_frames int) f32 {
	return math.sinf(f32(periods) * (2 * math.pi) * f32(frame) / f32(num_frames))
}

pub fn (mut cl Client) ping_sound(mut soundbuffer &f32, num_frames int, num_channels int) {
	ms := cl.sw.elapsed().milliseconds() - cl.sw_start_ms

	for frame := 0; frame < num_frames; frame++ {
		for ch := 0; ch < num_channels; ch++ {
			idx := frame * num_channels + ch
			if ms < 250 {
				soundbuffer[idx] = 0.5 * sintone(20, frame, num_frames)
			} else if ms < 300 {
				soundbuffer[idx] = 0.5 * sintone(25, frame, num_frames)
			} else if ms < 1500 {
				soundbuffer[idx] *= sintone(22, frame, num_frames)
			} else if ms < 1700 {
				cl.playing = -1
			}
		}
	}
}

fn audio_stream_callback(mut soundbuffer &f32, num_frames int, num_channels int, mut cl Client) {
	if cl.playing != -1 {
		if cl.reset_audio == false {
			cl.reset_audio = true
			cl.sw.restart()
			cl.sw_start_ms = cl.sw.elapsed().milliseconds()
		}

		if cl.playing == 0 {
			cl.ping_sound(mut soundbuffer, num_frames, num_channels)
		} else if cl.playing == 1 {
			cl.bytebeat(mut soundbuffer, num_frames, num_channels)
		}
	} else if cl.reset_audio {
		cl.reset_audio = false
		cl.sw.stop()

		for frame := 0; frame < num_frames; frame++ {
			for ch := 0; ch < num_channels; ch++ {
				idx := frame * num_channels + ch
				soundbuffer[idx] = 0
			}
		}
	}
}

pub fn (mut cl Client) tick() {
	for {
		if cl.snow {
			if cl.flakes.len < 60 {
				cl.flakes << Snowflake{
					x:          rand.int_in_range(0, cl.width) or { 0 }
					y:          0
					delay:      rand.int_in_range(0, 12) or { 0 }
					cycle_left: rand.int_in_range(3, 12) or { 0 }
				}
			}

			cl.update_snowflakes()
		}
		if cl.playing == 1 {
			if cl.play_timer >= 300 {
				cl.playing = -1
				cl.play_timer = 0
				cl.frame = 0
			} else {
				cl.play_timer++
			}
		}
		time.sleep(24 * time.millisecond)
	}
}

pub fn (mut cl Client) client_msg(message string) {
	cl.messages << ClientMessage{
		content: message
	}
	cl.update_chat(false)
}

pub fn (mut cl Client) chat_msg(message ChatMessage) {
	if message.reply != '' {
		mut preview := cl.get_message(message.reply)
		preview.is_preview = true
		cl.messages << preview
	}

	if message.owner != cl.id {
		if message.content.contains('@' + cl.get_nick()) {
			cl.play_audio(0)
		}
	}

	cl.messages << message
	cl.update_chat(message.owner == cl.id)
}

pub fn (mut cl Client) update() {
	previous_offset := cl.offset

	if cl.messages.len > cl.max_messages {
		cl.offset = cl.messages.len - cl.max_messages
	} else {
		cl.offset = 0
	}

	if cl.focused != -1 {
		if previous_offset < cl.offset {
			cl.focused -= cl.offset - previous_offset
		} else if previous_offset > cl.offset {
			cl.focused += previous_offset - cl.offset
		}
	}
}

pub fn (mut cl Client) update_chat(own bool) {
	if own
		|| (cl.messages.len > cl.max_messages && cl.offset > cl.messages.len - cl.max_messages - 6) {
		cl.update()
	}
}

pub fn (mut cl Client) get_message(message_id string) ChatMessage {
	for mut msg in cl.messages {
		if mut msg is ChatMessage {
			if msg.id == message_id {
				return msg.clone()
			}
		}
	}
	return ChatMessage{}
}

fn (mut cl Client) footer() {
	w, h := cl.tui.window_width, cl.tui.window_height
	cl.tui.draw_text(0, h - 1, '─'.repeat(w))
}

fn (mut cl Client) header() {
	cl.tui.draw_text(2, 1, '♦ Verris v' + version)
	cl.tui.draw_text(0, 2, '─'.repeat(cl.tui.window_width))
}

fn frame(mut cl Client) {
	cl.tui.clear()

	max_messages := cl.tui.window_height - 3 - padding

	if cl.width != cl.tui.window_width - padding {
		cl.width = cl.tui.window_width - padding
	}

	if cl.height != cl.tui.window_height - padding {
		cl.height = cl.tui.window_height - padding
	}

	if cl.max_messages != max_messages {
		cl.max_messages = max_messages
		cl.update()
	}

	for i in 0 .. cl.max_messages {
		if cl.messages.len < 0 {
			continue
		}
		if cl.offset + i > cl.messages.len - 1 {
			continue
		}

		mut message := cl.messages[cl.offset + i]

		mut msg := ''

		if mut message is ChatMessage {
			msg = message.format()
		} else {
			msg = message.content
		}

		for _, nick in cl.users {
			if message.content.contains('@' + nick) {
				msg = msg.replace('@' + nick, bg_cyan + '@' + nick + bg_reset)
			}
		}

		if i == cl.focused {
			msg = bold + bg_white + msg + reset
		}

		if cl.debug {
			msg = (cl.offset + i).str() + ': ' + msg
		}

		cl.tui.draw_text(padding, i + 1 + padding, msg)
	}

	cl.footer()
	cl.header()

	if cl.snow {
		cl.draw_snowflakes()
	}
	if cl.editing != '' {
		cl.tui.draw_text(0, cl.tui.window_height, 'editing > ' + cl.input)
		cl.tui.set_cursor_position(cl.cursor + 11, cl.tui.window_height)
	} else if cl.deleting != '' {
		cl.tui.draw_text(0, cl.tui.window_height, 'delete reason > ' + cl.input)
		cl.tui.set_cursor_position(cl.cursor + 17, cl.tui.window_height)
	} else if cl.replying != '' {
		cl.tui.draw_text(0, cl.tui.window_height, 'replying > ' + cl.input)
		cl.tui.set_cursor_position(cl.cursor + 12, cl.tui.window_height)
	} else {
		cl.tui.draw_text(0, cl.tui.window_height, '> ' + cl.input)
		cl.tui.set_cursor_position(cl.cursor + 3, cl.tui.window_height)
	}
	cl.tui.flush()
}

fn (mut cl Client) last_line() int {
	if cl.messages.len < cl.max_messages {
		return cl.messages.len
	} else {
		return cl.max_messages
	}
}

fn (mut cl Client) up() {
	if cl.deleting != '' || cl.editing != '' || cl.replying != '' {
		return
	}

	if cl.focused == -1 {
		cl.focused = cl.last_line() - 1
	} else {
		if cl.focused > 0 {
			cl.focused--
		} else {
			if cl.offset > 0 {
				cl.offset--
			}
		}
	}
}

fn (mut cl Client) down() {
	if cl.deleting != '' || cl.editing != '' || cl.replying != '' {
		return
	}

	if cl.focused == -1 {
		cl.focused = 0
	} else {
		if cl.focused == cl.last_line() - 1 {
			if cl.offset < cl.messages.len - cl.max_messages {
				cl.offset++
			}
		} else if cl.focused < cl.last_line() - 1 {
			cl.focused++
		}
	}
}

fn (mut cl Client) remove_char(input string, index int) string {
	mut runes := input.runes()
	runes.delete(index)
	return runes.string()
}

fn (mut cl Client) insert_char(input string, index int, ch string) string {
	mut runes := input.runes()
	runes.insert(index, ch.runes()[0])
	return runes.string()
}

fn (mut cl Client) append(ch string) {
	if cl.deleting != '' {
		if cl.input.runes().len >= 26 {
			return
		}
	}

	if cl.input.runes().len >= 60 {
		return
	}

	cl.input = cl.insert_char(cl.input, cl.cursor, ch)
	cl.cursor++
}

fn event(e &tui.Event, mut cl Client) {
	if e.typ == .key_down {
		if e.modifiers == .ctrl {
			if e.code == .e || e.code == .d || e.code == .r {
				if cl.focused != -1 {
					msg := cl.messages[cl.offset + cl.focused]

					if msg is ChatMessage {
						if !msg.deleted && !msg.is_preview {
							if e.code == .r {
								if cl.replying != '' {
									cl.replying = ''
								} else {
									cl.replying = msg.id
								}
								cl.input = ''
								cl.cursor = 0
							} else if msg.owner == cl.id {
								if e.code == .d {
									if cl.deleting != '' {
										cl.deleting = ''
									} else {
										cl.deleting = msg.id
									}
									cl.input = ''
									cl.cursor = 0
								} else if e.code == .e {
									if cl.editing != '' {
										cl.editing = ''
										cl.input = ''
										cl.cursor = 0
									} else {
										cl.editing = msg.id
										cl.original_message = msg.content
										cl.input = cl.original_message
										cl.cursor = msg.content.runes().len
									}
								}
							}
						}
					}
				}
			} else if e.code == .q {
				cl.conn.close() or {}
				exit(0)
			}
			return
		}

		match e.code {
			.escape {
				if cl.deleting != '' {
					cl.deleting = ''
				} else if cl.editing != '' {
					if cl.input == '' {
						cl.editing = ''
						cl.original_message = ''
						return
					}
				} else if cl.replying != '' {
					cl.replying = ''
				} else {
					if cl.input == '' {
						cl.focused = -1
					}
				}
				cl.input = ''
				cl.cursor = 0
			}
			.space {
				if cl.cursor != 0 {
					cl.append(' ')
				}
			}
			.enter {
				cl.input = cl.input.trim_space()

				if cl.deleting != '' {
					if cl.input != '' {
						cl.delete_message(cl.deleting, cl.input)
					} else {
						cl.delete_message(cl.deleting, '')
					}
					cl.deleting = ''
				} else if cl.input != '' {
					if cl.editing != '' {
						if cl.input != cl.original_message {
							cl.edit_message(cl.editing, cl.input)
							cl.editing = ''
							cl.original_message = ''
						} else {
							return
						}
					} else if cl.replying != '' {
						cl.reply_message(cl.replying, cl.input)
						cl.replying = ''
					} else {
						if cl.input.runes()[0].str() == '/' {
							if cl.input.runes().len > 1 {
								if cl.input.starts_with('/exit') {
									audio.shutdown()
									cl.conn.close() or {}
									exit(0)
								} else {
									cl.send_command(cl.input)
								}
							}
						} else {
							cl.send_message(cl.input)
						}
					}
				}
				cl.input = ''
				cl.cursor = 0
			}
			.right {
				if cl.cursor < cl.input.runes().len {
					cl.cursor++
				}
			}
			.left {
				if cl.cursor > 0 {
					cl.cursor--
				}
			}
			.up {
				cl.up()
			}
			.down {
				cl.down()
			}
			.home {
				cl.offset = 0

				if cl.focused != 0 {
					cl.focused = 0
				} else {
					cl.focused = -1
				}
			}
			.page_up {}
			.page_down {}
			.end {
				cl.update()

				if cl.focused != cl.last_line() - 1 {
					cl.focused = cl.last_line() - 1
				} else {
					cl.focused = -1
				}
			}
			.backspace {
				if cl.input != '' {
					if cl.cursor > 0 {
						cl.input = cl.remove_char(cl.input, cl.cursor - 1)
						cl.cursor--
					}
				}
			}
			.tab {}
			else {
				cl.append(e.utf8)
			}
		}
	} else if e.typ == .mouse_scroll {
		if e.direction == .up {
			cl.down()
		} else {
			cl.up()
		}
	} else if e.typ == .mouse_down || e.typ == .mouse_drag {
		if cl.deleting == '' && cl.editing == '' && cl.replying == '' {
			mut line := e.y - padding
			if line > cl.last_line() {
				cl.focused = -1
			} else {
				if cl.focused == line - 1 {
					cl.focused = -1
				} else {
					cl.focused = line - 1
				}
			}
		}
	}
}

fn main() {
	mut cl := &Client{}

	nick := os.input('nick: ')
	if nick == '' {
		exit(0)
	}

	ip := cmdline.option(os.args, '-ip', '0.0.0.0').str()
	port := cmdline.option(os.args, '-port', '13396').str()

	cl.conn = net.dial_tcp('${ip}:${port}') or { exit(0) }
	go cl.listen()
	go cl.tick()

	cl.send_login(nick)

	term.set_terminal_title('Verris')

	cl.sw = time.new_stopwatch()
	cl.sw.stop()

	audio.setup(
		stream_userdata_cb: audio_stream_callback
		user_data:          cl
	)

	cl.tui = tui.init(
		user_data:      cl
		frame_fn:       frame
		event_fn:       event
		capture_events: true
	)
	cl.tui.run()!

	audio.shutdown()
	cl.conn.close() or {}
}
