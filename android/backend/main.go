//go:build android

package main

/*
#include <jni.h>
static char* zenpm_string(JNIEnv* env, jstring value) {
    return value == 0 ? 0 : (char*)(*env)->GetStringUTFChars(env, value, 0);
}
static void zenpm_release(JNIEnv* env, jstring value, char* text) {
    if (text != 0) (*env)->ReleaseStringUTFChars(env, value, text);
}
*/
import "C"

import (
	"ZPM/internal/androidbackend"
)

func javaString(env *C.JNIEnv, value C.jstring) string {
	text := C.zenpm_string(env, value)
	if text == nil {
		return ""
	}
	defer C.zenpm_release(env, value, text)
	return C.GoString(text)
}

//export Java_org_zenlabs_zenpm_ZenPMService_nativeStart
func Java_org_zenlabs_zenpm_ZenPMService_nativeStart(env *C.JNIEnv, _ C.jclass, home C.jstring, logHome C.jstring, koreaderRoot C.jstring, port C.jint) {
	androidbackend.Start(javaString(env, home), javaString(env, logHome), javaString(env, koreaderRoot), int(port))
}

func main() {}
