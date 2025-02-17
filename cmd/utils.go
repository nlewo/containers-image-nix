package cmd

import (
	"encoding/json"
	"os"

	"github.com/nlewo/nix2container/types"

	v1 "github.com/opencontainers/image-spec/specs-go/v1"
)

func readPermsFile(filename string) (permPaths []types.PermPath, err error) {
	content, err := os.ReadFile(filename)
	if err != nil {
		return permPaths, err
	}
	err = json.Unmarshal(content, &permPaths)
	if err != nil {
		return permPaths, err
	}
	return
}

func readCapsFile(filename string) (capsPaths []types.CapabilityPath, err error) {
	content, err := os.ReadFile(filename)
	if err != nil {
		return capsPaths, err
	}
	err = json.Unmarshal(content, &capsPaths)
	if err != nil {
		return capsPaths, err
	}
	return
}

func readRewritesFile(filename string) (rewritePaths []types.RewritePath, err error) {
	content, err := os.ReadFile(filename)
	if err != nil {
		return rewritePaths, err
	}
	err = json.Unmarshal(content, &rewritePaths)
	if err != nil {
		return rewritePaths, err
	}
	return
}

func readHistoryFile(filename string) (history v1.History, err error) {
	content, err := os.ReadFile(filename)
	if err != nil {
		return history, err
	}
	err = json.Unmarshal(content, &history)
	if err != nil {
		return history, err
	}
	return
}
