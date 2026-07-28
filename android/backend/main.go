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
	"github.com/xZenLabs/zen-pm/internal/androidbackend"
)

func javaString(env *C.JNIEnv, value C.jstring) string {
	text := C.zenpm_string(env, value)
	if text == nil {
		return ""
	}
	defer C.zenpm_release(env, value, text)
	return C.GoString(text)
}

//export Java_org_zenlabs_zenpm_ZenPMService_nativeRun
func Java_org_zenlabs_zenpm_ZenPMService_nativeRun(env *C.JNIEnv, _ C.jclass, home C.jstring, logHome C.jstring, koreaderRoot C.jstring, socketPath C.jstring) {
	androidbackend.Run(javaString(env, home), javaString(env, logHome), javaString(env, koreaderRoot), javaString(env, socketPath))
}

//export Java_org_zenlabs_zenpm_ZenPMService_nativeStop
func Java_org_zenlabs_zenpm_ZenPMService_nativeStop(env *C.JNIEnv, clazz C.jclass) {
	androidbackend.Stop()
}

func main() {}
