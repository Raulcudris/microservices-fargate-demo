package com.makiia.userservice.dto;

public class HealthResponse {

    private String status;
    private String service;
    private String timestamp;

    public HealthResponse(String status, String service, String timestamp) {
        this.status = status;
        this.service = service;
        this.timestamp = timestamp;
    }

    public String getStatus() {
        return status;
    }

    public String getService() {
        return service;
    }

    public String getTimestamp() {
        return timestamp;
    }
}

