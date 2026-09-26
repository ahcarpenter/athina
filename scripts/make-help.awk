# Prints the Makefile's help, what plain `make` shows: each `##@` line starts a
# group, a target's `## ` text is its line in that group, and any other line
# starting `## ` is printed as it stands (the Variables group), all under one
# usage line.
BEGIN { print "Usage: make <target> [NAME=value]" }
/^##@ / {
	print ""
	print substr($0, 5)
	next
}
/^[a-z][a-z0-9-]*:.*## / {
	name = $0; sub(/:.*/, "", name)
	text = $0; sub(/^[^#]*## /, "", text)
	printf "  %-25s %s\n", name, text
	next
}
/^## / { printf "  %s\n", substr($0, 4) }
