package padding

import (
	"crypto/md5"
	"crypto/rand"
	"fmt"
	"math/big"
	"strconv"
	"strings"

	"github.com/sagernet/sing/common/atomic"
)

const (
	CheckMark = -1

	MaxSchemeBytes = 8 * 1024
	maxPackets     = 64
	maxEntries     = 32
	maxLength      = 16 * 1024
	maxSession     = 64 * 1024
	frameOverhead  = 7 // command, stream ID and length
)

var DefaultPaddingScheme = []byte(`stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000`)

type payloadRange struct {
	min, max int
}

type PaddingFactory struct {
	scheme    map[uint32][]payloadRange
	RawScheme []byte
	Stop      uint32
	Md5       string
}

func UpdatePaddingScheme(rawScheme []byte, to *atomic.TypedValue[*PaddingFactory]) bool {
	if p := NewPaddingFactory(rawScheme); p != nil {
		to.Store(p)
		return true
	}
	return false
}

func NewPaddingFactory(rawScheme []byte) *PaddingFactory {
	if len(rawScheme) == 0 || len(rawScheme) > MaxSchemeBytes {
		return nil
	}
	p := &PaddingFactory{
		RawScheme: append([]byte(nil), rawScheme...),
		Md5:       fmt.Sprintf("%x", md5.Sum(rawScheme)),
		scheme:    make(map[uint32][]payloadRange),
	}
	hasStop := false
	budget := 0
	for _, line := range strings.Split(string(rawScheme), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil
		}
		if key == "stop" {
			stop, err := strconv.ParseUint(value, 10, 32)
			if err != nil || hasStop || stop > maxPackets {
				return nil
			}
			p.Stop, hasStop = uint32(stop), true
			continue
		}
		index, err := strconv.ParseUint(key, 10, 32)
		if err != nil || index >= maxPackets || p.scheme[uint32(index)] != nil {
			return nil
		}
		tokens := strings.Split(value, ",")
		if len(tokens) > maxEntries {
			return nil
		}
		for i, token := range tokens {
			if token == "c" && index != 0 {
				p.scheme[uint32(index)] = append(p.scheme[uint32(index)], payloadRange{CheckMark, CheckMark})
				continue
			}
			low, high, ok := strings.Cut(token, "-")
			minLen, minErr := strconv.ParseUint(low, 10, 32)
			maxLen, maxErr := strconv.ParseUint(high, 10, 32)
			if !ok || minErr != nil || maxErr != nil || minLen == 0 || maxLen == 0 || minLen > maxLength || maxLen > maxLength {
				return nil
			}
			if minLen > maxLen {
				minLen, maxLen = maxLen, minLen
			}
			// The authentication packet uses only its first range and has no waste frame.
			if index != 0 {
				budget += int(maxLen) + frameOverhead
			} else if i == 0 {
				budget += int(maxLen)
			}
			if budget > maxSession {
				return nil
			}
			p.scheme[uint32(index)] = append(p.scheme[uint32(index)], payloadRange{int(minLen), int(maxLen)})
		}
	}
	if !hasStop {
		return nil
	}
	return p
}

func (p *PaddingFactory) GenerateRecordPayloadSizes(pkt uint32) (pktSizes []int) {
	for _, size := range p.scheme[pkt] {
		if size.min == size.max {
			pktSizes = append(pktSizes, size.min)
			continue
		}
		offset, err := rand.Int(rand.Reader, big.NewInt(int64(size.max-size.min)))
		if err != nil {
			pktSizes = append(pktSizes, size.min)
			continue
		}
		pktSizes = append(pktSizes, int(offset.Int64())+size.min)
	}
	return pktSizes
}
