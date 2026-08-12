package com.qzh.lanjingquiz.UI

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier

enum class HomeTab { Exams, Practice, Profile }

@Composable
fun AppRoot() {
    var selected by remember { mutableStateOf(HomeTab.Exams) }
    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(
                selected = selected == HomeTab.Exams,
                onClick = { selected = HomeTab.Exams },
                icon = { Icon(Icons.Filled.CheckCircle, contentDescription = null) },
                label = { Text("考试列表") },
            )
            NavigationBarItem(
                selected = selected == HomeTab.Practice,
                onClick = { selected = HomeTab.Practice },
                icon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                label = { Text("练习") },
            )
            NavigationBarItem(
                selected = selected == HomeTab.Profile,
                onClick = { selected = HomeTab.Profile },
                icon = { Icon(Icons.Filled.Person, contentDescription = null) },
                label = { Text("我的") },
            )
        }
    }) { padding ->
        Text("蓝鲸助手", Modifier.padding(padding))
    }
}
