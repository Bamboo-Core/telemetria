package main

import (
	"fmt"
	"os"
	"strings"
)

// Converte "huawei_xxx" em um nome de tipo válido (PascalCase).
func toTypeName(protoFile string) string {
	withoutPrefix := strings.TrimPrefix(protoFile, "huawei-")
	withoutDashes := strings.ReplaceAll(withoutPrefix, "-", " ")
	titleCase := strings.Title(withoutDashes)
	return strings.ReplaceAll(titleCase, " ", "")
}

func main() {
	protoFiles := os.Getenv("PROTO_FILES")
	if protoFiles == "" {
		fmt.Println("PROTO_FILES environment variable is not set")
		os.Exit(1)
	}

	files := strings.Split(protoFiles, " ")

	for _, file := range files {
		typeName := toTypeName(file)
		packageName := strings.ReplaceAll(file, "-", "_")
		fmt.Printf(`PathKey{ProtoPath: "%s.%s", Version: "1.0"}: []reflect.Type{reflect.TypeOf((*%s.%s)(nil))},`+"\n",
			packageName, typeName, packageName, typeName)
	}
}
