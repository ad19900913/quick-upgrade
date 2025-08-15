package com.ft.upgrade.entity;

import lombok.Data;
import lombok.EqualsAndHashCode;

import javax.persistence.*;
import java.time.LocalDateTime;

/**
 * 升级配置文件元数据实体
 * 
 * @author ft-team
 */
@Data
@EqualsAndHashCode(callSuper = false)
@Entity
@Table(name = "upgrade_configuration", indexes = {
    @Index(name = "idx_version", columnList = "version", unique = true),
    @Index(name = "idx_is_active", columnList = "is_active")
})
public class UpgradeConfigurationMeta {

    @Id
    @Column(name = "version", length = 20)
    private String version;

    /**
     * 配置描述
     */
    @Column(name = "description", length = 500)
    private String description;

    /**
     * 配置文件路径
     */
    @Column(name = "config_path", length = 500, nullable = false)
    private String configPath;

    /**
     * 文件校验和
     */
    @Column(name = "checksum", length = 64, nullable = false)
    private String checksum;

    /**
     * 创建时间
     */
    @Column(name = "created_time", nullable = false)
    private LocalDateTime createdTime;

    /**
     * 最后修改时间
     */
    @Column(name = "last_modified", nullable = false)
    private LocalDateTime lastModified;

    /**
     * 是否激活
     */
    @Column(name = "is_active", nullable = false)
    private Boolean isActive;

    /**
     * 创建者
     */
    @Column(name = "created_by", length = 50)
    private String createdBy;

    /**
     * 版本类型
     */
    @Enumerated(EnumType.STRING)
    @Column(name = "version_type", length = 20)
    private VersionType versionType;

    /**
     * 基线版本（补丁版本使用）
     */
    @Column(name = "base_version", length = 20)
    private String baseVersion;

    /**
     * 是否为主要升级
     */
    @Column(name = "is_major_upgrade")
    private Boolean isMajorUpgrade;

    @PrePersist
    protected void onCreate() {
        LocalDateTime now = LocalDateTime.now();
        this.createdTime = now;
        this.lastModified = now;
        if (this.isActive == null) {
            this.isActive = true;
        }
        if (this.isMajorUpgrade == null) {
            this.isMajorUpgrade = false;
        }
    }

    @PreUpdate
    protected void onUpdate() {
        this.lastModified = LocalDateTime.now();
    }

    /**
     * 版本类型枚举
     */
    public enum VersionType {
        BASELINE("基线版本"),
        PATCH("补丁版本");

        private final String description;

        VersionType(String description) {
            this.description = description;
        }

        public String getDescription() {
            return description;
        }
    }
}