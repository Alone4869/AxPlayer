package io.github.alone4869.axplayer

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

object TaskStore {
    private const val PREFS = "download_tasks"
    private const val KEY = "tasks"
    private const val MAX_TASKS = 100

    @Synchronized
    fun upsert(context: Context, task: JSONObject) {
        val tasks = readArray(context)
        val updated = JSONArray().put(task)
        for (index in 0 until tasks.length()) {
            val existing = tasks.optJSONObject(index) ?: continue
            if (existing.optString("id") != task.optString("id") && updated.length() < MAX_TASKS) {
                updated.put(existing)
            }
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, updated.toString())
            .apply()
    }

    /**
     * 读取任务列表。
     *
     * [runningIds] 是本进程里真正还有下载线程在跑的任务 id。持久化状态仍然是
     * queued/downloading、却不在这个集合里的任务，说明下载线程已经跟着进程一起
     * 没了（被系统回收、用户划掉后台卡片），这里统一改写成失败。否则界面会永远
     * 停在"下载中"，而取消请求又找不到对应的执行者，任务彻底卡死。
     */
    @Synchronized
    fun getTasks(context: Context, runningIds: Set<String> = emptySet()): List<Map<String, Any>> {
        val tasks = readArray(context)
        val localFiles = LocalDownloads.list(context)
        val result = buildList {
            for (index in 0 until tasks.length()) {
                tasks.optJSONObject(index)?.let { task ->
                    val fallbackTime = task.optString("id").substringBefore('-').toLongOrNull() ?: 0L
                    if (!task.has("createdAt")) task.put("createdAt", fallbackTime)
                    if (!task.has("completedAt")) {
                        task.put(
                            "completedAt",
                            if (task.optString("status") == "completed") fallbackTime else 0L,
                        )
                    }
                    markInterruptedIfStale(task, runningIds)
                    val localFile = localFiles
                        .filter { it.displayName == task.optString("fileName") }
                        .maxByOrNull { it.addedAt }
                    if (task.optLong("fileSize") <= 0L && localFile != null) {
                        task.put("fileSize", localFile.size)
                    }
                    if (task.optString("contentUri").isBlank() && localFile != null) {
                        task.put("contentUri", localFile.uri.toString())
                    }
                    if (!task.has("contentUri")) task.put("contentUri", "")
                    if (!task.has("sourceUrl")) task.put("sourceUrl", "")
                    if (!task.has("uploaded")) task.put("uploaded", false)
                    add(jsonToMap(task.toString()))
                }
            }
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, tasks.toString())
            .apply()
        return result
    }

    @Synchronized
    fun markUploaded(context: Context, ids: Set<String>): List<JSONObject> {
        val tasks = readArray(context)
        val updated = mutableListOf<JSONObject>()
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            if (task.optString("id") in ids) {
                task.put("uploaded", true)
                task.put("uploadedAt", System.currentTimeMillis())
                updated += task
            }
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, tasks.toString())
            .apply()
        return updated
    }

    /**
     * 把一个已经没有人执行的进行中任务改写为失败。
     *
     * 状态必须落在 failed 上，不能引入新状态名：Dart 侧的 [DownloadStatus]
     * 不认识未知值时会回退成 queued，那等于又把它放回"等待下载"，问题照旧。
     */
    private fun markInterruptedIfStale(task: JSONObject, runningIds: Set<String>) {
        val status = task.optString("status")
        if (status != "queued" && status != "downloading") return
        if (task.optString("id") in runningIds) return
        task.put("status", "failed")
        task.put("message", "下载已中断，请重新下载")
    }

    /**
     * 直接把任务改写为已取消，用于服务里根本没有对应下载线程的情况。
     * 返回改写后的任务，调用方据此广播给 Dart 侧刷新界面。
     */
    @Synchronized
    fun cancel(context: Context, id: String): JSONObject? {
        val tasks = readArray(context)
        var updated: JSONObject? = null
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            if (task.optString("id") != id) continue
            val status = task.optString("status")
            if (status == "queued" || status == "downloading") {
                task.put("status", "cancelled")
                task.put("message", "")
                updated = task
            }
        }
        if (updated != null) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY, tasks.toString())
                .apply()
        }
        return updated
    }

    @Synchronized
    fun delete(context: Context, ids: Set<String>) {
        val tasks = readArray(context)
        val retained = JSONArray()
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            if (task.optString("id") !in ids) retained.put(task)
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, retained.toString())
            .apply()
    }

    fun jsonToMap(json: String): Map<String, Any> {
        val value = JSONObject(json)
        return buildMap {
            value.keys().forEach { key -> put(key, value.opt(key) ?: "") }
        }
    }

    private fun readArray(context: Context): JSONArray {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
        return try {
            if (raw == null) JSONArray() else JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

}
