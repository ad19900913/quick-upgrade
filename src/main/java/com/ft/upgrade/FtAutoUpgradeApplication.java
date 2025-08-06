package com.ft.upgrade;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.transaction.annotation.EnableTransactionManagement;

/**
 * FT自动升级服务主应用类
 * 
 * @author ft-team
 * @version 1.0.0
 */
@SpringBootApplication
@EnableDiscoveryClient
@EnableCaching
@EnableAsync
@EnableTransactionManagement
public class FtAutoUpgradeApplication {

    public static void main(String[] args) {
        SpringApplication.run(FtAutoUpgradeApplication.class, args);
    }
}