package com.ft.upgrade.entity;

import lombok.Data;
import lombok.EqualsAndHashCode;
import org.hibernate.annotations.GenericGenerator;

import javax.persistence.*;
import java.time.LocalDateTime;

/**
 * 步骤执行记录实体
 * 
 * @author ft-team
 */
@Data
@EqualsAndHashCode(callSuper = false)
@Entity
@Table(name = "step_execution", indexes = {
    @Index(name = "idx_execution_id", columnList = "execution_id"),
    @Index(name = "idx_step_id", columnList = "step_id"),
    @Index(name = "idx_status", columnList = "status")
})
public class StepExecution {

    @Id
    @GeneratedValue(generator = "uuid")
    @GenericGenerator(name = "uuid", strategy = "uuid2")
    @Column(name = "id", length = 36)
    private String id;

    /**
     * 升级执行ID
     */
    @Column(name = "execution_id", length = 36, nullable = false)
    private String executionId;

    /**
     * 步骤ID
     */
    @Column(name = "step_id", length = 100, nullable = false)
    private String stepId;

    /**
     * 步骤名称
     */
    @Column(name = "step_name", length = 200, nullable = false)
    private String stepName;

    /**
     * 步骤类型
     */
    @Column(name = "step_type", length = 50, nullable = false)
    private String stepType;

    /**
     * 步骤状态
     */
    @Enumerated(EnumType.STRING)
    @Column(name = "status", length = 20, nullable = false)
    private StepStatus status;

    /**
     * 开始时间
     */
    @Column(name = "start_time")
    private LocalDateTime startTime;

    /**
     * 结束时间
     */
    @Column(name = "end_time")
    private LocalDateTime endTime;

    /**
     * 执行耗时（毫秒）
     */
    @Column(name = "duration")
    private Long duration;

    /**
     * 执行结果
     */
    @Lob
    @Column(name = "result")
    private String result;

    /**
     * 错误信息
     */
    @Lob
    @Column(name = "error_message")
    private String errorMessage;

    /**
     * 元数据（JSON格式）
     */
    @Lob
    @Column(name = "metadata")
    private String metadata;

    /**
     * 重试次数
     */
    @Column(name = "retry_count")
    private Integer retryCount;

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

    @PrePersist
    protected void onCreate() {
        LocalDateTime now = LocalDateTime.now();
        this.createdTime = now;
        this.updatedTime = now;
        if (this.status == null) {
            this.status = StepStatus.PENDING;
        }
        if (this.retryCount == null) {
            this.retryCount = 0;
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
     * 步骤状态枚举
     */
    public enum StepStatus {
        PENDING("待执行"),
        RUNNING("执行中"),
        SUCCESS("执行成功"),
        FAILED("执行失败"),
        SKIPPED("已跳过"),
        RETRYING("重试中");

        private final String description;

        StepStatus(String description) {
            this.description = description;
        }

        public String getDescription() {
            return description;
        }
    }
}