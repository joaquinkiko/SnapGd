## Encodable data structure, ready for sending/receiving over the network.
@abstract
class_name SnapEncodable extends RefCounted

## While true, intergers will use 64-bit encoding.
## While false, intergers will use 32-bit encoding.
## It's important that sender/receiver both have the same setting.
static var int64: bool = false
## While true, floats will use 64-bit encoding.
## While false, floats will use 32-bit encoding.
## It's important that sender/receiver both have the same setting.
static var _double_floats: bool = OS.has_feature("double")

@abstract
## Encodes data for sending over network.
func encode() -> PackedByteArray

@abstract
## Decodes data from [method encode]. Both mutates self, and returns self.
func decode(bytes: PackedByteArray) -> SnapEncodable

## Writes interger to buffer
static func write_int(buf: StreamPeerBuffer, v: int) -> void:
	if int64: buf.put_64(v)
	else: buf.put_32(v)

## Reads interger from buffer
static func read_int(buf: StreamPeerBuffer) -> int:
	return buf.get_64() if int64 else buf.get_32()

## Writes float to buffer
static func write_float(buf: StreamPeerBuffer, v: float) -> void:
	if _double_floats: buf.put_double(v)
	else: buf.put_float(v)

## Reads float from buffer
static func read_float(buf: StreamPeerBuffer) -> float:
	return buf.get_double() if _double_floats else buf.get_float()

## Writes utf8 string to buffer, headed by u16 interger size
static func write_string(buf: StreamPeerBuffer, v: String) -> void:
	var b := v.to_utf8_buffer()
	buf.put_u16(b.size())
	buf.put_data(b)

## Reads utf8 string to buffer that is headed by u16 interger size
static func read_string(buf: StreamPeerBuffer) -> String:
	var len := buf.get_u16()
	return buf.get_data(len)[1].get_string_from_utf8()

## Writes raw byte-array headed by u16 interger size
static func write_bytes(buf: StreamPeerBuffer, v: PackedByteArray) -> void:
	buf.put_u16(v.size())
	buf.put_data(v)

## Reads raw byte-array headed by u16 interger size
static func read_bytes(buf: StreamPeerBuffer) -> PackedByteArray:
	var len := buf.get_u16()
	return buf.get_data(len)[1]

## Writes a variant, headed by u8 type
static func write_variant(buf: StreamPeerBuffer, value: Variant) -> void:
	match typeof(value):
		TYPE_NIL:
			buf.put_u8(TYPE_NIL)
		TYPE_BOOL:
			buf.put_u8(TYPE_BOOL)
			buf.put_u8(1 if value else 0)
		TYPE_INT:
			buf.put_u8(TYPE_INT)
			write_int(buf, value)
		TYPE_FLOAT:
			buf.put_u8(TYPE_FLOAT)
			write_float(buf, value)
		TYPE_VECTOR2:
			buf.put_u8(TYPE_VECTOR2)
			write_float(buf, value.x)
			write_float(buf, value.y)
		TYPE_VECTOR3:
			buf.put_u8(TYPE_VECTOR3)
			write_float(buf, value.x)
			write_float(buf, value.y)
			write_float(buf, value.z)
		TYPE_VECTOR2I:
			buf.put_u8(TYPE_VECTOR2I)
			write_int(buf, value.x)
			write_int(buf, value.y)
		TYPE_VECTOR3I:
			buf.put_u8(TYPE_VECTOR3I)
			write_int(buf, value.x)
			write_int(buf, value.y)
			write_int(buf, value.z)
		TYPE_QUATERNION:
			buf.put_u8(TYPE_QUATERNION)
			write_float(buf, value.x)
			write_float(buf, value.y)
			write_float(buf, value.z)
			write_float(buf, value.w)
		TYPE_STRING:
			buf.put_u8(TYPE_STRING)
			write_string(buf, value)
		TYPE_STRING_NAME:
			buf.put_u8(TYPE_STRING_NAME)
			write_string(buf, String(value))
		TYPE_PACKED_BYTE_ARRAY:
			buf.put_u8(TYPE_PACKED_BYTE_ARRAY)
			write_bytes(buf, value)
		TYPE_ARRAY:
			buf.put_u8(TYPE_ARRAY)
			buf.put_u32(value.size())
			for item in value:
				write_variant(buf, item)
		TYPE_DICTIONARY:
			buf.put_u8(TYPE_DICTIONARY)
			buf.put_u32(value.size())
			for key in value:
				write_variant(buf, key)
				write_variant(buf, value[key])
		_:
			buf.put_u8(typeof(value))
			buf.put_var(value, false)

## Reads a variant, headed by u8 type
static func read_variant(buf: StreamPeerBuffer) -> Variant:
	var tag := buf.get_u8()
	match tag:
		TYPE_NIL: return null
		TYPE_BOOL: return buf.get_u8() == 1
		TYPE_INT: return read_int(buf)
		TYPE_FLOAT: return read_float(buf)
		TYPE_VECTOR2: return Vector2(read_float(buf), read_float(buf))
		TYPE_VECTOR3: return Vector3(read_float(buf), read_float(buf), read_float(buf))
		TYPE_VECTOR2I: return Vector2i(read_int(buf), read_int(buf))
		TYPE_VECTOR3I: return Vector3i(read_int(buf), read_int(buf), read_int(buf))
		TYPE_QUATERNION: return Quaternion(read_float(buf), read_float(buf), read_float(buf), read_float(buf))
		TYPE_STRING: return read_string(buf)
		TYPE_STRING_NAME: return StringName(read_string(buf))
		TYPE_PACKED_BYTE_ARRAY: return read_bytes(buf)
		TYPE_ARRAY:
			var n := buf.get_u32()
			var arr: Array = []
			for i in n:
				arr.append(read_variant(buf))
			return arr
		TYPE_DICTIONARY:
			var n := buf.get_u32()
			var dict: Dictionary = {}
			for i in n:
				var k = read_variant(buf)
				dict[k] = read_variant(buf)
			return dict
		_: return buf.get_var(false)
