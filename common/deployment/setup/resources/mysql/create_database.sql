create database IDENTITY_DB character set latin1;
create database UM_DB character set latin1;
create database REG_DB character set latin1;

use IDENTITY_DB; source ~/wso2is/dbscripts/identity/mysql.sql;
use IDENTITY_DB; source ~/wso2is/dbscripts/consent/mysql.sql;
use UM_DB; source ~/wso2is/dbscripts/mysql.sql;
use REG_DB; source ~/wso2is/dbscripts/mysql.sql;

-- ── Usage metering tables (org.wso2.carbon.identity.usage.metering) ──────────
-- Added to IDENTITY_DB so the metering component uses its default (fallback)
-- datasource — no custom datasource / identity.xml / master-datasource change
-- needed. Mirrors mau/src/main/resources/db/usage_schema.sql.
use IDENTITY_DB;
CREATE TABLE IF NOT EXISTS IDN_MAU_COUNT (
    ID            BIGINT        NOT NULL AUTO_INCREMENT,
    USER_ID       VARCHAR(255)  NOT NULL,
    TENANT_DOMAIN VARCHAR(255)  NOT NULL,
    MONTH_YEAR    CHAR(6)       NOT NULL,
    LAST_LOGIN    BIGINT        NOT NULL,
    PRIMARY KEY (ID),
    UNIQUE KEY UK_IDN_MAU_COUNT (USER_ID, TENANT_DOMAIN, MONTH_YEAR),
    INDEX IDX_IDN_MAU_COUNT_MONTH (MONTH_YEAR)
);
CREATE TABLE IF NOT EXISTS IDN_USAGE_COUNT (
    NODE_ID       VARCHAR(128)  NOT NULL,
    TENANT_DOMAIN VARCHAR(256)  NOT NULL,
    COUNT_TYPE    VARCHAR(50)   NOT NULL,
    COUNT         INT           NOT NULL DEFAULT 0,
    COUNT_PERIOD  VARCHAR(20)   NOT NULL,
    CREATED_TIME  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                                         ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT PK_IDN_USAGE_COUNT
        PRIMARY KEY (NODE_ID, TENANT_DOMAIN, COUNT_TYPE, COUNT_PERIOD),
    INDEX IDX_IDN_USAGE_COUNT_TYPE (COUNT_TYPE, COUNT_PERIOD)
);
