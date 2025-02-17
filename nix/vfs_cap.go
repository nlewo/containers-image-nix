package nix

import (
	"encoding/binary"
	"fmt"
)

const (
	// VFS_CAP_REVISION_3 is version 3 of the capability implementation
	VFS_CAP_REVISION_3 = 0x03000000
	
	// VFS_CAP_U32 defines the number of 32-bit words per capability set
	VFS_CAP_U32 = 2
	
	// VFS_CAP_FLAGS_EFFECTIVE is the flag indicating if the effective bit is set
	VFS_CAP_FLAGS_EFFECTIVE = 0x000001

	// Capability constants
	CAP_NET_BIND_SERVICE = 10
)

// CapData represents the capability data pair of permitted and inheritable flags
type CapData struct {
	Permitted    uint32 // Little endian
	Inheritable  uint32 // Little endian
}

// VFSCapData represents the full capability data structure as stored in the filesystem
type VFSCapData struct {
	MagicEtc uint32           // Little endian
	Data     [VFS_CAP_U32]CapData
	RootID   uint32          // Little endian (new in revision 3)
}

// NewVFSCapData creates a new VFSCapData structure with the given capabilities
func NewVFSCapData(permitted, inheritable uint32, effective bool, rootid uint32) *VFSCapData {
	magic := VFS_CAP_REVISION_3
	if effective {
		magic |= VFS_CAP_FLAGS_EFFECTIVE
	}
	
	return &VFSCapData{
		MagicEtc: uint32(magic),
		Data: [VFS_CAP_U32]CapData{
			{
				Permitted:   permitted,
				Inheritable: inheritable,
			},
			{
				Permitted:   0,
				Inheritable: 0,
			},
		},
		RootID: rootid,
	}
}

// ToBytes converts the VFSCapData structure to a byte slice in little endian format
func (vfs *VFSCapData) ToBytes() []byte {
	// Size is now: 4 (magic) + (4 + 4) * 2 (two CapData structs) + 4 (rootid) = 24 bytes
	b := make([]byte, 24)
	
	// Write magic_etc
	binary.LittleEndian.PutUint32(b[0:], vfs.MagicEtc)
	
	// Write first CapData
	binary.LittleEndian.PutUint32(b[4:], vfs.Data[0].Permitted)
	binary.LittleEndian.PutUint32(b[8:], vfs.Data[0].Inheritable)
	
	// Write second CapData
	binary.LittleEndian.PutUint32(b[12:], vfs.Data[1].Permitted)
	binary.LittleEndian.PutUint32(b[16:], vfs.Data[1].Inheritable)
	
	// Write rootid
	binary.LittleEndian.PutUint32(b[20:], vfs.RootID)
	
	return b
}

// FromBytes parses a byte slice into a VFSCapData structure
func FromBytes(b []byte) (*VFSCapData, error) {
	if len(b) < 12 { // 4 + (4 + 4) * VFS_CAP_U32
		return nil, fmt.Errorf("byte slice too short: got %d bytes, want at least 12", len(b))
	}
	
	vfs := &VFSCapData{}
	
	// Read magic_etc
	vfs.MagicEtc = binary.LittleEndian.Uint32(b[0:])
	
	// Read permitted
	vfs.Data[0].Permitted = binary.LittleEndian.Uint32(b[4:])
	
	// Read inheritable
	vfs.Data[0].Inheritable = binary.LittleEndian.Uint32(b[8:])
	
	return vfs, nil
}