#include "AthinaSQLiteShim.h"

int athina_sqlite_keep_wal_on_close(sqlite3 *db) {
    return sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, (int *)0);
}
