extension AppUpdate {
    /// Shell helper that replaces the running app after it exits.
    /// Arguments: $1 pid to wait for, $2 installed app, $3 staged app, $4 staging folder to clean up.
    ///
    /// A failure to move the installed app aside aborts without touching it. The installed copy is only
    /// removed for rollback once a backup is known to exist, and the backup is kept until the new copy
    /// is in place. A backup left by an interrupted earlier run is restored rather than deleted.
    public static let swapScript = """
    while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.3; done
    backup="$2.previous"
    if [ ! -e "$2" ] && [ -d "$backup" ]; then /bin/mv "$backup" "$2" || exit 1; fi
    /bin/rm -rf "$backup"
    if [ -e "$backup" ] || ! /bin/mv "$2" "$backup"; then
      /usr/bin/open "$2"
      exit 1
    fi
    if [ -d "$backup" ] && [ ! -e "$2" ] && /usr/bin/ditto "$3" "$2" && [ -d "$2/Contents/MacOS" ]; then
      /bin/rm -rf "$backup" "$4"
    elif [ -d "$backup" ]; then
      /bin/rm -rf "$2"
      /bin/mv "$backup" "$2"
    fi
    /usr/bin/open "$2"
    """
}
