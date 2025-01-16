import net
import time
import rand

const admin_password = 'abc123'

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
	mut value := u32(0)
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
	return int(value)
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

struct User {
mut:
	id    int
	name  string
	admin bool
}

struct Message {
mut:
	owner         int
	id            string
	content       string
	timestamp     string
	edited        bool
	deleted       bool
	delete_reason string
	reply         string
}

struct Server {
mut:
	conn     &net.TcpListener = unsafe { nil }
	clients  map[string]net.TcpConn
	users    map[string]User
	messages map[string]Message
}

pub fn (mut srv Server) generate_message_id() string {
	timestamp := time.ticks()
	random_number := rand.intn(9999999999999999) or { 0 }
	timestamp_part := timestamp % 10000000000
	message_id := '${timestamp_part}${random_number % 1000000000}'
	return message_id
}

pub fn (mut srv Server) send_event(addr string, id int) {
	mut event_packet := Packet{}
	event_packet.write_varint(6)
	event_packet.write_varint(id)
	event_packet.encode()

	time.sleep(24 * time.millisecond)
	srv.clients[addr].write(event_packet.buffer) or {}
}

pub fn (mut srv Server) broadcast_event(id int) {
	mut event_packet := Packet{}
	event_packet.write_varint(6)
	event_packet.write_varint(id)
	event_packet.encode()

	for _, mut c in srv.clients {
		time.sleep(24 * time.millisecond)
		c.write(event_packet.buffer) or {}
	}
}

pub fn (mut srv Server) send_message(addr string, message string) {
	mut system_message := Packet{}
	system_message.write_varint(3)
	system_message.write_string(message)
	system_message.encode()

	time.sleep(24 * time.millisecond)
	srv.clients[addr].write(system_message.buffer) or {}
}

pub fn (mut srv Server) broadcast_message(message string) {
	mut system_message := Packet{}
	system_message.write_varint(3)
	system_message.write_string(message)
	system_message.encode()

	for _, mut c in srv.clients {
		time.sleep(24 * time.millisecond)
		c.write(system_message.buffer) or {}
	}
}

pub fn (mut srv Server) handle_command(addr string, command string) {
	parts := command.split(' ')
	if parts.len == 0 {
		return
	}
	command_name := parts[0]
	params := parts[1..]

	user := srv.users[addr]

	if command_name == '/auth' {
		if user.admin {
			srv.send_message(addr, 'already logged in')
			return
		}

		if params.len == 0 {
			srv.send_message(addr, 'usage: /auth <password>')
			return
		}

		if params[0] == admin_password {
			srv.users[addr].admin = true
			srv.send_message(addr, 'auth successful')
		} else {
			srv.send_message(addr, 'wrong password')
		}
	} else if command_name == '/say' {
		if user.admin {
			if params.len == 0 {
				srv.send_message(addr, 'enter a message')
				return
			}
			srv.broadcast_message(params[0])
		} else {
			srv.send_message(addr, 'you are not an admin!')
		}
	} else if command_name == '/clear' {
		if user.admin {
			srv.broadcast_event(0)
		} else {
			srv.send_message(addr, 'you are not an admin!')
		}
	} else if command_name == '/snow' {
		if user.admin {
			srv.broadcast_event(1)
		} else {
			srv.send_message(addr, 'you are not an admin!')
		}
	} else if command_name == '/music' {
		if user.admin {
			srv.broadcast_event(2)
			srv.broadcast_message(user.name + ' started a party!')
		} else {
			srv.send_message(addr, 'you are not an admin!')
		}
	} else if command_name == '/party' {
		if user.admin {
			srv.broadcast_event(1)
			srv.broadcast_event(2)
			srv.broadcast_message(user.name + ' started a party!')
		} else {
			srv.send_message(addr, 'you are not an admin!')
		}
	} else {
		srv.send_message(addr, 'no such command')
	}
}

pub fn (mut srv Server) handle_client(mut conn net.TcpConn) {
	mut buf := []u8{len: 1024}

	peer_addr := conn.peer_addr() or { return }
	addr := peer_addr.str()

	for {
		read := conn.read(mut buf) or {
			if err.str() == 'none' {
				break
			}
			continue
		}
		data := buf[..read].clone()

		if data.len == 0 {
			continue
		}

		mut packet := Packet.new(data)
		packet.decode()

		if packet.id == 0 { // enter room
			mut user := User{}
			user.id = srv.users.len
			user.name = packet.read_string().trim_space()

			println('client joined: ${user.name}(${user.id})')

			srv.users[addr] = user

			mut info := Packet{} // send its id to user
			info.write_varint(0)
			info.write_varint(user.id)
			info.encode()

			time.sleep(24 * time.millisecond)
			conn.write(info.buffer) or {}

			mut introduce := Packet{}
			introduce.write_varint(1)
			introduce.write_varint(user.id)
			introduce.write_string(user.name)
			introduce.encode()

			time.sleep(24 * time.millisecond)
			conn.write(introduce.buffer) or {}

			for addr2, mut c in srv.clients {
				if addr2 != addr {
					time.sleep(24 * time.millisecond)
					c.write(introduce.buffer) or {} // introduce this user to others

					mut introduce2 := Packet{}
					introduce2.write_varint(1)
					introduce2.write_varint(srv.users[addr2].id)
					introduce2.write_string(srv.users[addr2].name)
					introduce2.encode()

					time.sleep(24 * time.millisecond)
					conn.write(introduce2.buffer) or {} // introduce every user to this user
				}
			}

			srv.broadcast_message(user.name + ' has joined')
		}

		if packet.id == 1 { // send message
			id := srv.users[addr].id
			message := packet.read_string().trim_space()

			if message == '' {
				continue
			}
			if message.runes().len > 60 {
				continue
			}

			println('message from ${srv.users[addr].name}(${id}): ' + message)

			msg_id := srv.generate_message_id()
			timestamp := (time.ticks() / 1000).str()

			mut msg := Message{
				owner:     id
				id:        msg_id
				content:   message
				timestamp: timestamp
			}

			srv.messages[msg_id] = msg

			mut broadcast := Packet{}
			broadcast.write_varint(2)
			broadcast.write_varint(id) // owner
			broadcast.write_string(msg_id) // message id
			broadcast.write_string(timestamp) // timestamp
			broadcast.write_string(message) // message
			broadcast.write_string('')
			broadcast.encode()

			for _, mut c in srv.clients {
				time.sleep(24 * time.millisecond)
				c.write(broadcast.buffer) or {}
			}
		} else if packet.id == 2 { // delete message
			msg_id := packet.read_string()
			if msg_id !in srv.messages.keys() {
				continue
			}
			id := srv.users[addr].id

			msg := srv.messages[msg_id]
			if msg.deleted {
				continue
			}
			owner := msg.owner

			if id == owner {
				reason := packet.read_string().trim_space()

				if reason.runes().len > 26 {
					continue
				}

				srv.messages[msg_id].edited = false
				srv.messages[msg_id].deleted = true
				srv.messages[msg_id].delete_reason = reason

				mut delete_broadcast := Packet{}
				delete_broadcast.write_varint(4)
				delete_broadcast.write_string(msg_id)
				delete_broadcast.write_string(reason)
				delete_broadcast.encode()

				for _, mut c in srv.clients {
					time.sleep(24 * time.millisecond)
					c.write(delete_broadcast.buffer) or {}
				}
			}
		} else if packet.id == 3 { // edit message
			msg_id := packet.read_string()
			if msg_id !in srv.messages.keys() {
				continue
			}
			id := srv.users[addr].id

			msg := srv.messages[msg_id]
			if msg.deleted {
				continue
			}
			owner := msg.owner

			if id == owner {
				new_message := packet.read_string().trim_space()

				if new_message == srv.messages[msg_id].content {
					continue
				}

				srv.messages[msg_id].content = new_message
				srv.messages[msg_id].edited = true

				mut edit_broadcast := Packet{}
				edit_broadcast.write_varint(5)
				edit_broadcast.write_string(msg_id)
				edit_broadcast.write_string(new_message)
				edit_broadcast.encode()

				for _, mut c in srv.clients {
					time.sleep(24 * time.millisecond)
					c.write(edit_broadcast.buffer) or {}
				}
			}
		} else if packet.id == 4 { // reply message
			id := srv.users[addr].id
			message_id := packet.read_string()
			reply := packet.read_string().trim_space()

			if reply == '' {
				continue
			}

			println('reply from ${srv.users[addr].name}(${id}): ' + reply)

			msg_id := srv.generate_message_id()
			timestamp := (time.ticks() / 1000).str()

			mut msg := Message{
				owner:     id
				id:        msg_id
				content:   reply
				timestamp: timestamp
				reply:     message_id
			}

			srv.messages[msg_id] = msg

			mut broadcast := Packet{}
			broadcast.write_varint(2)
			broadcast.write_varint(id) // owner
			broadcast.write_string(msg_id) // message id
			broadcast.write_string(timestamp) // timestamp
			broadcast.write_string(reply) // message
			broadcast.write_string(message_id) // message
			broadcast.encode()

			for _, mut c in srv.clients {
				time.sleep(24 * time.millisecond)
				c.write(broadcast.buffer) or {}
			}
		} else if packet.id == 5 { // command packet
			command := packet.read_string()
			if command == '' {
				continue
			}
			srv.handle_command(addr, command)
		}
	}

	srv.clients.delete(addr)
	conn.close() or {}
}

pub fn (mut srv Server) run() {
	listen_addr := '0.0.0.0:13396'
	srv.conn = net.listen_tcp(net.AddrFamily.ip, listen_addr, net.ListenOptions{}) or { return }

	for {
		mut conn := srv.conn.accept() or { continue }
		peer_addr := conn.peer_addr() or { continue }
		addr := peer_addr.str()
		srv.clients[addr] = conn
		go srv.handle_client(mut conn)
	}
}

fn main() {
	mut srv := Server{}
	srv.run()
}
