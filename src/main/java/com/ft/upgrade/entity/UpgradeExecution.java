package com.ft.upgrade.entity;

import lombok.Data;
import lombok.EqualsAndHashCode;
import org.hibernate.annotations.GenericGenerator;

import javax.persistence.*;
import java.time.LocalDateTime;

/**
 * 升级执行记录实体
 * 
 * @author ft-team
 */
@Data
@EqualsAndHashCode(callSuper = false)
@Entity
@Table(name = "upgrade_execution")
public class UpgradeExecution {

    @Id
    @GeneratedValue(generator = "uuid")
    @GenericGenerator(name = "uuid", strategy = "uuid2")
    @Column(name = "execution_id", length = 36)
    private String executionId;

    /**
     * 升级前版本号
     */
    @Column(name = "source_version", length = 20, nullable = false)
    private String sourceVersion;

    /**
     * 升级后版本号
     */
    @Column(name = "target_version", length = 20, nullable = false)
    private String targetVersion;

    /**
     * 局点ID
     */
    @Column(name = "site_id", length = 10, nullable = false)
    private String siteId;

    /**
     * 环境信息
     */
    @Column(name = "environment", length = 20, nullable = false)
    private String environment;

    /**
     * 执行状态
     */
    @Enumerated(EnumType.STRING)
    @Column(name = "status", length = 20, nullable = false)
    private ExecutionStatus status;

    /**
     * 开始时间
     */
    @Column(name = "start_time", nullable = false)
    private LocalDateTime startTime;

    /**
     * 结束时间
     */
    @Column(name = "end_time")
    private LocalDateTime endTime;

    /**
     * 当前执行的步骤ID
     */
    @Column(name = "current_step_id", length = 100)
    private String currentStepId;

    /**
     * 断点数据（JSON格式）
     */
    @Lob
    @Column(name = "breakpoint_data")
    private String breakpointData;

    /**
     * 总步骤数
     */
    @Column(name = "total_steps")
    private Integer totalSteps;

    /**
     * 已完成步骤数
     */
    @Column(name = "completed_steps")
    private Integer completedSteps;

    /**
     * 错误信息
     */
    @Lob
    @Column(name = "error_message")
    private String errorMessage;

    /**
     * 创建时间
     */
    @Column(name = "created_time", nullable = false)
    private LocalDateTime createdTime;

    /**
     * 更新时间
     */
    @Column(name = "updated_time", nullable = false)
    private LocalDateTime updatedTime;

    /**
     * 创建者
     */
    @Column(name = "created_by", length = 50)
    private String createdBy;

    /**
     * 执行耗时（毫秒）
     */
    @Column(name = "duration")
    private Long duration;

    @PrePersist
    protected void onCreate() {
        LocalDateTime now = LocalDateTime.now();
        this.createdTime = now;
        this.updatedTime = now;
        if (this.status == null) {
            this.status = ExecutionStatus.PENDING;
        }
        if (this.completedSteps == null) {
            this.completedSteps = 0;
        }
    }

    @PreUpdate
    protected void onUpdate() {
        this.updatedTime = LocalDateTime.now();
        if (this.endTime != null && this.startTime != null) {
            this.duration = java.time.Duration.between(this.startTime, this.endTime).toMillis();
        }
    }

    /**
     * 执行状态枚举
     */
    public enum ExecutionStatus {
        PENDING("待执行"),
        RUNNING("执行中"),
        SUCCESS("执行成功"),
        FAILED("执行失败"),
        CANCELLED("已取消"),
        PAUSED("已暂停");

        private final String description;

        ExecutionStatus(String description) {
            this.description = description;
        }

        public String getDescription() {
            return description;
        }
    }
}