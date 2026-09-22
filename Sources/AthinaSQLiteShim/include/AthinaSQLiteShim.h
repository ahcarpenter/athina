#ifndef ATHINA_SQLITE_SHIM_H
#define ATHINA_SQLITE_SHIM_H

#include <sqlite3.h>

/// `sqlite3_db_config` is variadic, which Swift cannot call, so the one
/// setting the app needs from it is spelled out here: a connection that
/// leaves the write-ahead log as it found it when it closes, rather than
/// folding it into the database file.
int athina_sqlite_keep_wal_on_close(sqlite3 *db);

#endif
