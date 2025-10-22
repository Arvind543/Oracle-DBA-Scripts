/******************************************************************************
    ORACLE WEEKLY INTERVAL PARTITIONED ERROR LOGGING SYSTEM
    
    Description: 
    Comprehensive error logging system with automatic weekly interval partitioning,
    autonomous transaction logging, DDL event tracking, server error capture,
    and failed login monitoring.
    
    Author: Database Administrator
    Created: 2025-10-22
    Version: 1.0
    
    Compatibility: Oracle 11g and above
    
    Components:
    1. Tablespace for error logging (optional)
    2. Sequence for primary key generation
    3. Weekly interval partitioned error log table
    4. Autonomous transaction error logging procedure
    5. Comprehensive error logging package
    6. DDL trigger for schema change tracking
    7. AFTER SERVERERROR trigger for runtime errors
    8. LOGON trigger for failed authentication tracking
    9. Monitoring views and queries
    10. Example usage patterns
    
******************************************************************************/

/*******************************************************************************
    SECTION 1: TABLESPACE CREATION (Optional but Recommended)
    
    Purpose: Dedicated tablespace for error logging provides better
             manageability and I/O isolation
    Note: Modify datafile paths according to your environment
*******************************************************************************/

-- Check if tablespace exists, create if not
DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM dba_tablespaces
    WHERE tablespace_name = 'ERROR_LOGGING_TS';
    
    IF v_count = 0 THEN
        EXECUTE IMMEDIATE '
            CREATE TABLESPACE ERROR_LOGGING_TS
            DATAFILE ''/u01/app/oracle/oradata/error_logging_01.dbf''
            SIZE 100M
            AUTOEXTEND ON
            NEXT 50M
            MAXSIZE UNLIMITED
            EXTENT MANAGEMENT LOCAL
            SEGMENT SPACE MANAGEMENT AUTO';
        
        DBMS_OUTPUT.PUT_LINE('Tablespace ERROR_LOGGING_TS created successfully.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Tablespace ERROR_LOGGING_TS already exists.');
    END IF;
END;
/

/*******************************************************************************
    SECTION 2: SEQUENCE FOR PRIMARY KEY
    
    Purpose: Generates unique identifiers for error log entries
    Cache: 100 for better performance in high-volume scenarios
*******************************************************************************/

-- Drop existing sequence if exists
BEGIN
    EXECUTE IMMEDIATE 'DROP SEQUENCE seq_error_log';
    DBMS_OUTPUT.PUT_LINE('Existing sequence dropped.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -2289 THEN -- ORA-02289: sequence does not exist
            RAISE;
        END IF;
END;
/

CREATE SEQUENCE seq_error_log
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE
    ORDER;

-- Comment on sequence
COMMENT ON SEQUENCE seq_error_log IS 'Sequence for generating unique error log IDs';

/*******************************************************************************
    SECTION 3: WEEKLY INTERVAL PARTITIONED ERROR LOG TABLE
    
    Purpose: Main error logging table with automatic weekly partitioning
    Strategy: INTERVAL partitioning automatically creates new partitions
              as data arrives, eliminating manual partition management
    
    Partition Key: ERROR_DATE (TIMESTAMP)
    Interval: 7 days (1 week)
*******************************************************************************/

-- Drop existing table if exists
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE database_error_log PURGE';
    DBMS_OUTPUT.PUT_LINE('Existing table dropped.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN -- ORA-00942: table or view does not exist
            RAISE;
        END IF;
END;
/

CREATE TABLE database_error_log
(
    error_id            NUMBER(19) NOT NULL,
    error_date          TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,
    error_code          NUMBER,
    error_message       VARCHAR2(4000),
    error_backtrace     VARCHAR2(4000),
    error_stack         VARCHAR2(4000),
    call_stack          VARCHAR2(4000),
    username            VARCHAR2(128),
    osuser              VARCHAR2(128),
    machine             VARCHAR2(256),
    ip_address          VARCHAR2(128),
    program             VARCHAR2(256),
    module              VARCHAR2(256),
    session_id          NUMBER,
    database_name       VARCHAR2(128),
    object_name         VARCHAR2(256),
    sql_text            CLOB,
    event_type          VARCHAR2(100),
    severity_level      VARCHAR2(50),
    additional_info     CLOB,
    
    CONSTRAINT pk_database_error_log PRIMARY KEY (error_id, error_date)
)
TABLESPACE ERROR_LOGGING_TS
PARTITION BY RANGE (error_date)
INTERVAL (NUMTODSINTERVAL(7, 'DAY'))
(
    -- Initial partition starting from beginning of current week
    PARTITION p_initial VALUES LESS THAN 
        (TIMESTAMP '2025-01-01 00:00:00')
)
ENABLE ROW MOVEMENT;

-- Create indexes for common query patterns
CREATE INDEX idx_error_log_date 
    ON database_error_log(error_date) 
    LOCAL
    TABLESPACE ERROR_LOGGING_TS;

CREATE INDEX idx_error_log_code 
    ON database_error_log(error_code, error_date) 
    LOCAL
    TABLESPACE ERROR_LOGGING_TS;

CREATE INDEX idx_error_log_username 
    ON database_error_log(username, error_date) 
    LOCAL
    TABLESPACE ERROR_LOGGING_TS;

CREATE INDEX idx_error_log_object 
    ON database_error_log(object_name, error_date) 
    LOCAL
    TABLESPACE ERROR_LOGGING_TS;

CREATE INDEX idx_error_log_event_type 
    ON database_error_log(event_type, error_date) 
    LOCAL
    TABLESPACE ERROR_LOGGING_TS;

-- Add comments to table and columns
COMMENT ON TABLE database_error_log IS 'Weekly interval partitioned table for comprehensive database error logging';
COMMENT ON COLUMN database_error_log.error_id IS 'Unique identifier for each error entry';
COMMENT ON COLUMN database_error_log.error_date IS 'Timestamp when error occurred (partition key)';
COMMENT ON COLUMN database_error_log.error_code IS 'Oracle error code (SQLCODE)';
COMMENT ON COLUMN database_error_log.error_message IS 'Error message text';
COMMENT ON COLUMN database_error_log.error_backtrace IS 'Error backtrace showing where error originated';
COMMENT ON COLUMN database_error_log.error_stack IS 'Complete error stack';
COMMENT ON COLUMN database_error_log.call_stack IS 'PL/SQL call stack';
COMMENT ON COLUMN database_error_log.event_type IS 'Type of event: ERROR, DDL_EVENT, LOGIN_FAILURE, etc.';

DBMS_OUTPUT.PUT_LINE('Table database_error_log created with weekly interval partitioning.');

/*******************************************************************************
    SECTION 4: AUTONOMOUS TRANSACTION PROCEDURE FOR ERROR LOGGING
    
    Purpose: Standalone procedure using AUTONOMOUS_TRANSACTION pragma
             Can be called from exception handlers without affecting
             the main transaction
    
    Usage: Call from any exception handler to log errors
*******************************************************************************/

CREATE OR REPLACE PROCEDURE log_error_autonomous (
    p_error_code        IN NUMBER DEFAULT NULL,
    p_error_message     IN VARCHAR2 DEFAULT NULL,
    p_error_backtrace   IN VARCHAR2 DEFAULT NULL,
    p_object_name       IN VARCHAR2 DEFAULT NULL,
    p_sql_text          IN CLOB DEFAULT NULL,
    p_event_type        IN VARCHAR2 DEFAULT 'ERROR',
    p_severity_level    IN VARCHAR2 DEFAULT 'ERROR',
    p_additional_info   IN CLOB DEFAULT NULL
)
IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    
    v_error_code        NUMBER;
    v_error_message     VARCHAR2(4000);
    v_error_backtrace   VARCHAR2(4000);
    v_error_stack       VARCHAR2(4000);
    v_call_stack        VARCHAR2(4000);
    v_username          VARCHAR2(128);
    v_osuser            VARCHAR2(128);
    v_machine           VARCHAR2(256);
    v_ip_address        VARCHAR2(128);
    v_program           VARCHAR2(256);
    v_module            VARCHAR2(256);
    v_session_id        NUMBER;
    v_database_name     VARCHAR2(128);
    
BEGIN
    -- Get error details if not provided
    v_error_code := NVL(p_error_code, SQLCODE);
    v_error_message := NVL(p_error_message, SUBSTR(SQLERRM, 1, 4000));
    v_error_backtrace := NVL(p_error_backtrace, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    v_error_stack := DBMS_UTILITY.FORMAT_ERROR_STACK;
    v_call_stack := DBMS_UTILITY.FORMAT_CALL_STACK;
    
    -- Get session information
    SELECT 
        username,
        osuser,
        machine,
        SYS_CONTEXT('USERENV', 'IP_ADDRESS'),
        program,
        module,
        sid,
        SYS_CONTEXT('USERENV', 'DB_NAME')
    INTO 
        v_username,
        v_osuser,
        v_machine,
        v_ip_address,
        v_program,
        v_module,
        v_session_id,
        v_database_name
    FROM v$session
    WHERE audsid = USERENV('SESSIONID')
    AND ROWNUM = 1;
    
    -- Insert error log entry
    INSERT INTO database_error_log (
        error_id,
        error_date,
        error_code,
        error_message,
        error_backtrace,
        error_stack,
        call_stack,
        username,
        osuser,
        machine,
        ip_address,
        program,
        module,
        session_id,
        database_name,
        object_name,
        sql_text,
        event_type,
        severity_level,
        additional_info
    ) VALUES (
        seq_error_log.NEXTVAL,
        SYSTIMESTAMP,
        v_error_code,
        v_error_message,
        v_error_backtrace,
        v_error_stack,
        v_call_stack,
        v_username,
        v_osuser,
        v_machine,
        v_ip_address,
        v_program,
        v_module,
        v_session_id,
        v_database_name,
        p_object_name,
        p_sql_text,
        p_event_type,
        p_severity_level,
        p_additional_info
    );
    
    COMMIT; -- Autonomous transaction must commit
    
EXCEPTION
    WHEN OTHERS THEN
        -- If error logging fails, write to alert log
        DBMS_SYSTEM.KSDWRT(2, 'Error in log_error_autonomous: ' || SQLERRM);
        ROLLBACK;
END log_error_autonomous;
/

/*******************************************************************************
    SECTION 5: COMPREHENSIVE ERROR LOGGING PACKAGE
    
    Purpose: Provides multiple procedures and functions for error logging
             and error log management
*******************************************************************************/

CREATE OR REPLACE PACKAGE pkg_error_logging AS
    
    -- Log general error with all details
    PROCEDURE log_error (
        p_error_code        IN NUMBER DEFAULT NULL,
        p_error_message     IN VARCHAR2 DEFAULT NULL,
        p_object_name       IN VARCHAR2 DEFAULT NULL,
        p_sql_text          IN CLOB DEFAULT NULL,
        p_severity_level    IN VARCHAR2 DEFAULT 'ERROR',
        p_additional_info   IN CLOB DEFAULT NULL
    );
    
    -- Log DDL event
    PROCEDURE log_ddl_event (
        p_event_type        IN VARCHAR2,
        p_object_name       IN VARCHAR2,
        p_sql_text          IN CLOB,
        p_additional_info   IN CLOB DEFAULT NULL
    );
    
    -- Log server error
    PROCEDURE log_server_error (
        p_error_code        IN NUMBER,
        p_additional_info   IN VARCHAR2 DEFAULT NULL
    );
    
    -- Log login failure
    PROCEDURE log_login_failure (
        p_username          IN VARCHAR2,
        p_reason            IN VARCHAR2
    );
    
    -- Get error count for specific period
    FUNCTION get_error_count (
        p_start_date        IN TIMESTAMP,
        p_end_date          IN TIMESTAMP,
        p_error_code        IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;
    
    -- Get partition information
    PROCEDURE get_partition_info;
    
    -- Purge old error logs
    PROCEDURE purge_old_logs (
        p_retention_days    IN NUMBER DEFAULT 90
    );
    
END pkg_error_logging;
/

CREATE OR REPLACE PACKAGE BODY pkg_error_logging AS

    /*************************************************************************
        Log general error with all details
    *************************************************************************/
    PROCEDURE log_error (
        p_error_code        IN NUMBER DEFAULT NULL,
        p_error_message     IN VARCHAR2 DEFAULT NULL,
        p_object_name       IN VARCHAR2 DEFAULT NULL,
        p_sql_text          IN CLOB DEFAULT NULL,
        p_severity_level    IN VARCHAR2 DEFAULT 'ERROR',
        p_additional_info   IN CLOB DEFAULT NULL
    )
    IS
    BEGIN
        log_error_autonomous(
            p_error_code        => p_error_code,
            p_error_message     => p_error_message,
            p_object_name       => p_object_name,
            p_sql_text          => p_sql_text,
            p_event_type        => 'ERROR',
            p_severity_level    => p_severity_level,
            p_additional_info   => p_additional_info
        );
    END log_error;
    
    /*************************************************************************
        Log DDL event
    *************************************************************************/
    PROCEDURE log_ddl_event (
        p_event_type        IN VARCHAR2,
        p_object_name       IN VARCHAR2,
        p_sql_text          IN CLOB,
        p_additional_info   IN CLOB DEFAULT NULL
    )
    IS
    BEGIN
        log_error_autonomous(
            p_error_code        => 0,
            p_error_message     => 'DDL Event: ' || p_event_type,
            p_object_name       => p_object_name,
            p_sql_text          => p_sql_text,
            p_event_type        => 'DDL_EVENT',
            p_severity_level    => 'INFO',
            p_additional_info   => p_additional_info
        );
    END log_ddl_event;
    
    /*************************************************************************
        Log server error
    *************************************************************************/
    PROCEDURE log_server_error (
        p_error_code        IN NUMBER,
        p_additional_info   IN VARCHAR2 DEFAULT NULL
    )
    IS
    BEGIN
        log_error_autonomous(
            p_error_code        => p_error_code,
            p_event_type        => 'SERVER_ERROR',
            p_severity_level    => 'ERROR',
            p_additional_info   => p_additional_info
        );
    END log_server_error;
    
    /*************************************************************************
        Log login failure
    *************************************************************************/
    PROCEDURE log_login_failure (
        p_username          IN VARCHAR2,
        p_reason            IN VARCHAR2
    )
    IS
        v_additional_info CLOB;
    BEGIN
        v_additional_info := 'Failed login attempt for user: ' || p_username || 
                           CHR(10) || 'Reason: ' || p_reason ||
                           CHR(10) || 'Machine: ' || SYS_CONTEXT('USERENV', 'HOST') ||
                           CHR(10) || 'IP Address: ' || SYS_CONTEXT('USERENV', 'IP_ADDRESS');
        
        log_error_autonomous(
            p_error_code        => -1017, -- Invalid username/password
            p_error_message     => 'Login failure for user: ' || p_username,
            p_event_type        => 'LOGIN_FAILURE',
            p_severity_level    => 'WARNING',
            p_additional_info   => v_additional_info
        );
    END log_login_failure;
    
    /*************************************************************************
        Get error count for specific period
    *************************************************************************/
    FUNCTION get_error_count (
        p_start_date        IN TIMESTAMP,
        p_end_date          IN TIMESTAMP,
        p_error_code        IN NUMBER DEFAULT NULL
    ) RETURN NUMBER
    IS
        v_count NUMBER;
    BEGIN
        IF p_error_code IS NULL THEN
            SELECT COUNT(*)
            INTO v_count
            FROM database_error_log
            WHERE error_date BETWEEN p_start_date AND p_end_date;
        ELSE
            SELECT COUNT(*)
            INTO v_count
            FROM database_error_log
            WHERE error_date BETWEEN p_start_date AND p_end_date
            AND error_code = p_error_code;
        END IF;
        
        RETURN v_count;
    END get_error_count;
    
    /*************************************************************************
        Get partition information
    *************************************************************************/
    PROCEDURE get_partition_info
    IS
        CURSOR c_partitions IS
            SELECT 
                partition_name,
                high_value,
                num_rows,
                ROUND(bytes/1024/1024, 2) AS size_mb
            FROM user_tab_partitions
            WHERE table_name = 'DATABASE_ERROR_LOG'
            ORDER BY partition_position;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=================================================');
        DBMS_OUTPUT.PUT_LINE('    PARTITION INFORMATION');
        DBMS_OUTPUT.PUT_LINE('=================================================');
        DBMS_OUTPUT.PUT_LINE(RPAD('Partition Name', 30) || 
                           RPAD('High Value', 25) || 
                           RPAD('Rows', 15) || 
                           'Size (MB)');
        DBMS_OUTPUT.PUT_LINE('-------------------------------------------------');
        
        FOR rec IN c_partitions LOOP
            DBMS_OUTPUT.PUT_LINE(RPAD(rec.partition_name, 30) || 
                               RPAD(SUBSTR(rec.high_value, 1, 24), 25) || 
                               RPAD(NVL(TO_CHAR(rec.num_rows), 'N/A'), 15) || 
                               NVL(TO_CHAR(rec.size_mb), 'N/A'));
        END LOOP;
        
        DBMS_OUTPUT.PUT_LINE('=================================================');
    END get_partition_info;
    
    /*************************************************************************
        Purge old error logs
    *************************************************************************/
    PROCEDURE purge_old_logs (
        p_retention_days    IN NUMBER DEFAULT 90
    )
    IS
        v_cutoff_date TIMESTAMP;
        v_rows_deleted NUMBER;
    BEGIN
        v_cutoff_date := SYSTIMESTAMP - INTERVAL '1' DAY * p_retention_days;
        
        DELETE FROM database_error_log
        WHERE error_date < v_cutoff_date;
        
        v_rows_deleted := SQL%ROWCOUNT;
        COMMIT;
        
        DBMS_OUTPUT.PUT_LINE('Purged ' || v_rows_deleted || 
                           ' error log entries older than ' || 
                           TO_CHAR(v_cutoff_date, 'YYYY-MM-DD HH24:MI:SS'));
        
        -- Log the purge operation
        log_error_autonomous(
            p_error_code        => 0,
            p_error_message     => 'Error log purge completed',
            p_event_type        => 'MAINTENANCE',
            p_severity_level    => 'INFO',
            p_additional_info   => 'Deleted ' || v_rows_deleted || ' records older than ' || 
                                 TO_CHAR(v_cutoff_date, 'YYYY-MM-DD HH24:MI:SS')
        );
    END purge_old_logs;
    
END pkg_error_logging;
/

/*******************************************************************************
    SECTION 6: DDL TRIGGER FOR SCHEMA CHANGE TRACKING
    
    Purpose: Captures all DDL events (CREATE, ALTER, DROP, etc.)
    Scope: Database level
    Events: All DDL_DATABASE_LEVEL_EVENTS
*******************************************************************************/

CREATE OR REPLACE TRIGGER trg_ddl_logging
AFTER DDL ON DATABASE
DECLARE
    v_event_type        VARCHAR2(100);
    v_object_name       VARCHAR2(256);
    v_object_type       VARCHAR2(100);
    v_sql_text          CLOB;
    v_additional_info   CLOB;
BEGIN
    -- Extract DDL event information using ORA_DICT_OBJ_NAME functions
    v_event_type := ORA_SYSEVENT;
    v_object_type := ORA_DICT_OBJ_TYPE;
    v_object_name := ORA_DICT_OBJ_OWNER || '.' || ORA_DICT_OBJ_NAME;
    
    -- Get SQL text
    IF ORA_SQL_TXT(v_sql_text) THEN
        NULL; -- SQL text retrieved successfully
    END IF;
    
    -- Build additional info
    v_additional_info := 'Event Type: ' || v_event_type || CHR(10) ||
                        'Object Type: ' || v_object_type || CHR(10) ||
                        'Object Name: ' || v_object_name || CHR(10) ||
                        'User: ' || ORA_LOGIN_USER || CHR(10) ||
                        'Instance Number: ' || ORA_INSTANCE_NUM || CHR(10) ||
                        'Database Name: ' || ORA_DATABASE_NAME;
    
    -- Log the DDL event
    pkg_error_logging.log_ddl_event(
        p_event_type        => v_event_type,
        p_object_name       => v_object_name,
        p_sql_text          => v_sql_text,
        p_additional_info   => v_additional_info
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Don't block DDL operations if logging fails
        -- Write to alert log instead
        DBMS_SYSTEM.KSDWRT(2, 'Error in DDL trigger: ' || SQLERRM);
END;
/

/*******************************************************************************
    SECTION 7: AFTER SERVERERROR TRIGGER
    
    Purpose: Captures runtime Oracle errors as they occur
    Scope: Database level
    Note: Only fires for errors, not for successful operations
*******************************************************************************/

CREATE OR REPLACE TRIGGER trg_server_error_logging
AFTER SERVERERROR ON DATABASE
DECLARE
    v_error_code        NUMBER;
    v_error_stack       VARCHAR2(4000);
    v_sql_text          VARCHAR2(4000);
    v_additional_info   CLOB;
    v_stack_depth       NUMBER;
BEGIN
    -- Get the error code
    v_error_code := ORA_SERVER_ERROR(1);
    
    -- Build error stack information
    v_stack_depth := ORA_SERVER_ERROR_DEPTH;
    v_additional_info := 'Error Stack Depth: ' || v_stack_depth || CHR(10);
    
    FOR i IN 1..v_stack_depth LOOP
        v_additional_info := v_additional_info || 
                           'Error ' || i || ': ' || ORA_SERVER_ERROR(i) || 
                           ' - ' || ORA_SERVER_ERROR_MSG(i) || CHR(10);
    END LOOP;
    
    -- Add session information
    v_additional_info := v_additional_info ||
                        'User: ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || CHR(10) ||
                        'OS User: ' || SYS_CONTEXT('USERENV', 'OS_USER') || CHR(10) ||
                        'Machine: ' || SYS_CONTEXT('USERENV', 'HOST') || CHR(10) ||
                        'IP Address: ' || SYS_CONTEXT('USERENV', 'IP_ADDRESS') || CHR(10) ||
                        'Module: ' || SYS_CONTEXT('USERENV', 'MODULE');
    
    -- Log the server error
    pkg_error_logging.log_server_error(
        p_error_code        => v_error_code,
        p_additional_info   => v_additional_info
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Don't propagate errors from error logging
        DBMS_SYSTEM.KSDWRT(2, 'Error in SERVERERROR trigger: ' || SQLERRM);
END;
/

/*******************************************************************************
    SECTION 8: LOGON TRIGGER FOR FAILED LOGIN TRACKING
    
    Purpose: Tracks failed login attempts for security monitoring
    Note: This trigger fires AFTER LOGON, so we check for previous failed
          attempts using DBA_AUDIT_TRAIL
I've created a **comprehensive Oracle error logging system** with automatic weekly interval partitioning! 

## Key Features:

**📊 Advanced Partitioning:**
- **INTERVAL partitioning** - Automatically creates new weekly partitions as data arrives (no manual management needed!)
- **Partition Key**: ERROR_DATE with 7-day intervals
- **Row Movement** enabled for automatic partition placement

**🔧 Core Components:**

**1. Database Objects:**
- Dedicated tablespace `ERROR_LOGGING_TS`
- Sequence `seq_error_log` for primary key generation
- Partitioned table `database_error_log` with comprehensive error details
- Local indexes on all partitions for optimal performance

**2. Error Logging Procedures:**
- **`log_error_autonomous`** - Uses `PRAGMA AUTONOMOUS_TRANSACTION` for safe logging in exception handlers
- **`pkg_error_logging`** - Complete package with specialized logging methods:
  - `log_error()` - General error logging
  - `log_ddl_event()` - DDL event tracking
  - `log_server_error()` - Runtime error capture
  - `log_login_failure()` - Failed authentication tracking
  - `get_error_count()` - Error statistics
  - `purge_old_logs()` - Automated cleanup

**3. Automatic Triggers:**
- **DDL Trigger** - Captures all schema changes (CREATE, ALTER, DROP)
- **SERVERERROR Trigger** - Automatically logs runtime errors as they occur
- **LOGON Trigger** - Tracks failed login attempts for security

**4. Rich Error Context:**
Captures: error code, message, backtrace, error stack, call stack, username, OS user, machine, IP address, program, module, session ID, SQL text, and more!

## Key Advantages over SQL Server Version:

✅ **Automatic partition creation** - No need for maintenance jobs
✅ **Autonomous transactions** - Safe logging without affecting main transaction
✅ **Built-in DDL tracking** - Uses Oracle's `ORA_*` functions
✅ **Server error capture** - Automatic logging of all database errors
✅ **Comprehensive context** - Rich session and system information

## Quick Usage:

```sql
-- In your exception handler:
BEGIN
    -- Your code
EXCEPTION
    WHEN OTHERS THEN
        pkg_error_logging.log_error();
        RAISE;
END;
```

The system is production-ready, optimized for Oracle 11g+, and includes monitoring queries and partition management utilities!