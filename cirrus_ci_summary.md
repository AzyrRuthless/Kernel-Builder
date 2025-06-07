# Cirrus CI Resource Allocation and Compute Credits Summary

This document summarizes findings regarding resource allocation on Cirrus CI, particularly for free tier usage on public repositories.

## Availability of 8 CPUs / 16 GB RAM on Free Tier

Based on general cloud service models and the typical limitations of free tiers, it is **highly unlikely** that a configuration of 8 CPUs and 16 GB RAM is directly available on Cirrus CI's standard free tier for public repositories.

*   **Free Tier Characteristics:** Free tiers are designed for experimentation, small projects, and to give users a taste of the service. They usually offer minimal CPU (often shared or burstable with low baselines) and RAM (typically 1-2 GB, sometimes less).
*   **Resource-Intensive Configurations:** An 8 CPU / 16 GB RAM setup is a substantial resource allocation, typically found in mid-to-high-tier paid plans on most cloud platforms. Offering this for free would be economically unsustainable for the provider at a large scale.

While Cirrus CI aims to be generous with open-source projects, there are still practical limits. The exact default resources for public repositories on Cirrus CI would be specified in their official documentation, but the "compute credits" system is a key indicator of how they manage these resources.

## "Not enough compute credits to prioritize tasks!" Message

This message within the Cirrus CI ecosystem signifies that your build tasks are experiencing delays or are not running with desired performance because your account/project has exhausted its available compute credits.

*   **Compute Credits Explained:** Cirrus CI, like many cloud services (especially those with free or burstable tiers), uses a compute credit system to manage CPU usage.
    *   Projects earn credits over time when using less than a baseline CPU allocation.
    *   When a build task requires more CPU power (bursting), it consumes these credits.
*   **Meaning of the Message:**
    *   **Exhausted Credits:** Your builds have used up the accrued credits.
    *   **Throttling:** As a result, your tasks are likely being throttled to a baseline (lower) CPU performance. This means builds will take longer.
    *   **Loss of Prioritization:** With no credits, your tasks cannot "bid" for higher priority or burst capacity. They will be queued or run at a reduced capacity, especially if the platform is busy.
    *   **Impact:** Longer build times, potential timeouts for very long tasks, and an inability to accelerate urgent builds.

## Monthly Free Allowance & Compute Credits for OSS Projects

Cirrus CI is known for its support of Open Source Software (OSS) projects.

*   **OSS Allowance:** Public repositories on platforms like GitHub typically receive a generous monthly allowance of compute credits for free. The exact amount can vary and would be detailed in Cirrus CI's specific terms for OSS projects. This allowance is designed to cover the build and test needs of most open-source projects.
*   **How Credits Work for OSS:**
    *   OSS projects usually start with a pool of credits.
    *   Each build task consumes credits based on its duration and the resources it uses (primarily CPU time).
    *   If a project's builds are very frequent or resource-intensive, they might consume credits faster than they are replenished by the monthly allowance or the natural accrual rate (if applicable to the free tier beyond a fixed monthly grant).
    *   When the monthly allowance is depleted, and no other credits are available, the "Not enough compute credits..." message appears, and performance is limited until the next refresh cycle or if alternative resources are provided.

## Achieving 8 CPUs / 16 GB RAM

If your project requires a consistent 8 CPUs and 16 GB RAM, the standard free tier is unlikely to meet this need directly. Here's how such a configuration might be achieved:

1.  **Paid Plans (Standard Cloud Providers):**
    *   Most major cloud providers (AWS, GCP, Azure) offer virtual machine instances with 8 vCPUs and 16 GB RAM (or similar) as part of their paid offerings. You would pay for this usage.
    *   Cirrus CI might have paid tiers that offer such dedicated resources, though this is less common for CI/CD providers themselves to offer *dedicated large VMs* directly, as they often focus on orchestrating tasks on various backends.

2.  **Cirrus CI Paid Tiers (if available for larger resources):**
    *   Check Cirrus CI's pricing or enterprise plans. They might offer higher resource allocations or dedicated capacity for a fee.

3.  **"Bring Your Own Infrastructure" (BYOI) / Self-Hosted Runners:**
    *   This is a common and powerful model that Cirrus CI supports.
    *   **How it works:** You set up your own machine (physical or a virtual machine you rent from a cloud provider like AWS, GCP, Azure) with the desired 8 CPUs / 16 GB RAM.
    *   You then install the Cirrus CI agent/runner software on this machine and connect it to your Cirrus CI account.
    *   **Benefits:**
        *   **Full Control:** You have complete control over the hardware specifications, operating system, and installed software.
        *   **Dedicated Resources:** Your builds get dedicated access to the 8 CPUs and 16 GB RAM, ensuring consistent performance without relying on shared credit pools for such high demands.
        *   **Cost Management:** You pay your cloud provider directly for the infrastructure, which might be more predictable or cost-effective for sustained high resource needs than relying on CI provider credits.
    *   **Considerations:** You are responsible for managing and maintaining this infrastructure (updates, security, etc.).

4.  **Sponsored OSS Programs or Credits:**
    *   Some cloud providers or CI/CD services offer special programs for prominent OSS projects, potentially granting larger resource pools or credits. This would require application or qualification.

**In summary for Cirrus CI:** For consistent 8 CPU / 16 GB RAM, the most probable solutions are to explore Cirrus CI's paid options (if they offer such tiers) or, more commonly, to use their "bring your own infrastructure" feature by connecting your own self-hosted runner that has these specifications. Relying on the standard free tier compute credits for such a demanding configuration is generally not feasible for sustained workloads.
