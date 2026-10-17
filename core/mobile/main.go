package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"encoding/json"
	"nodescope/core/engine"
	"unsafe"
)

func output(v any) *C.char {
	bytes, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"error":"编码失败"}`)
	}
	return C.CString(string(bytes))
}

//export NSParse
func NSParse(input *C.char) *C.char { return output(engine.ParseSubscription(C.GoString(input))) }

//export NSFetch
func NSFetch(input *C.char) *C.char { return output(engine.FetchSubscription(C.GoString(input))) }

//export NSNewRun
func NSNewRun() C.longlong { return C.longlong(engine.NewRun()) }

//export NSCancelRun
func NSCancelRun(id C.longlong) { engine.CancelRun(int64(id)) }

//export NSEndRun
func NSEndRun(id C.longlong) { engine.EndRun(int64(id)) }

//export NSTest
func NSTest(id C.longlong, config *C.char, options *C.char) *C.char {
	var opts engine.Options
	if json.Unmarshal([]byte(C.GoString(options)), &opts) != nil {
		return output(map[string]string{"error": "无效参数"})
	}
	return output(engine.TestNode(int64(id), C.GoString(config), opts))
}

//export NSFree
func NSFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func main() {}
