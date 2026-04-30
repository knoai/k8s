package com.example;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.*;

import java.util.*;
import java.util.concurrent.*;

@SpringBootApplication
@RestController
public class JavaPerfApp {

    private static final Map<String, byte[]> LEAK_MAP = new ConcurrentHashMap<>();
    private final Semaphore connectionPool;

    public JavaPerfApp() {
        int poolSize = Integer.parseInt(System.getenv().getOrDefault("DB_POOL_SIZE", "20"));
        this.connectionPool = new Semaphore(poolSize);
    }

    public static void main(String[] args) {
        SpringApplication.run(JavaPerfApp.class, args);
    }

    @GetMapping("/api/health")
    public Map<String, String> health() {
        Map<String, String> status = new HashMap<>();
        status.put("status", "healthy");
        status.put("jvm", System.getProperty("java.version"));
        status.put("gc", getGCName());
        return status;
    }

    @GetMapping("/api/gc-info")
    public Map<String, Object> gcInfo() {
        Map<String, Object> info = new HashMap<>();
        Runtime runtime = Runtime.getRuntime();
        info.put("maxMemory", runtime.maxMemory() / 1024 / 1024 + " MB");
        info.put("totalMemory", runtime.totalMemory() / 1024 / 1024 + " MB");
        info.put("freeMemory", runtime.freeMemory() / 1024 / 1024 + " MB");
        info.put("usedMemory", (runtime.totalMemory() - runtime.freeMemory()) / 1024 / 1024 + " MB");
        info.put("leakMapSize", LEAK_MAP.size());
        return info;
    }

    @GetMapping("/api/slow")
    public Map<String, Object> slowEndpoint() {
        Map<String, Object> result = new HashMap<>();
        long start = System.currentTimeMillis();
        try {
            if (connectionPool.tryAcquire(5, TimeUnit.SECONDS)) {
                try {
                    Thread.sleep(100);
                    result.put("status", "success");
                } finally {
                    connectionPool.release();
                }
            } else {
                result.put("status", "timeout");
                result.put("error", "Connection pool exhausted");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            result.put("status", "error");
        }
        result.put("elapsedMs", System.currentTimeMillis() - start);
        return result;
    }

    @GetMapping("/api/memory-leak")
    public Map<String, Object> memoryLeak(@RequestParam(defaultValue = "1000") int count) {
        Map<String, Object> result = new HashMap<>();
        for (int i = 0; i < count; i++) {
            LEAK_MAP.put(UUID.randomUUID().toString(), new byte[1024 * 10]);
        }
        result.put("leakedEntries", count);
        result.put("totalMapSize", LEAK_MAP.size());
        result.put("estimatedLeakMb", (LEAK_MAP.size() * 10) / 1024);
        return result;
    }

    @GetMapping("/api/deadlock")
    public Map<String, Object> triggerDeadlock() {
        Map<String, Object> result = new HashMap<>();
        Object lockA = new Object();
        Object lockB = new Object();
        Thread t1 = new Thread(() -> {
            synchronized (lockA) {
                try { Thread.sleep(100); } catch (InterruptedException e) {}
                synchronized (lockB) {}
            }
        });
        Thread t2 = new Thread(() -> {
            synchronized (lockB) {
                try { Thread.sleep(100); } catch (InterruptedException e) {}
                synchronized (lockA) {}
            }
        });
        t1.start();
        t2.start();
        result.put("status", "deadlock_triggered");
        return result;
    }

    @GetMapping("/api/alloc")
    public Map<String, Object> allocate(@RequestParam(defaultValue = "100") int mb) {
        Map<String, Object> result = new HashMap<>();
        long start = System.currentTimeMillis();
        List<byte[]> garbage = new ArrayList<>();
        for (int i = 0; i < mb; i++) {
            garbage.add(new byte[1024 * 1024]);
        }
        result.put("allocatedMb", mb);
        result.put("elapsedMs", System.currentTimeMillis() - start);
        return result;
    }

    private String getGCName() {
        List<String> gcNames = new ArrayList<>();
        for (java.lang.management.GarbageCollectorMXBean gc : java.lang.management.ManagementFactory.getGarbageCollectorMXBeans()) {
            gcNames.add(gc.getName());
        }
        return String.join(", ", gcNames);
    }
}
