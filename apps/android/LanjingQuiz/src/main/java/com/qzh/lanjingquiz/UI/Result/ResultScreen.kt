package com.qzh.lanjingquiz.UI.Result

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.Network.ExamResult
import com.qzh.lanjingquiz.UI.DSAccent
import com.qzh.lanjingquiz.UI.DSBlue
import com.qzh.lanjingquiz.UI.DSOrange
import com.qzh.lanjingquiz.UI.HomeTab

/**
 * 交卷结果页(iOS ResultView 移植):{score} 分 / 击败全国 {beatRate}% / 当前排名 #{rank}。
 */
@Composable
fun ResultScreen(
    result: ExamResult,
    examName: String,
    appState: AppState,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("🦉", fontSize = 80.sp)
        Text("单元挑战完成！", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = Color(0xFF3C3C3C))
        Text(
            "${result.score} 分",
            fontSize = 64.sp,
            fontWeight = FontWeight.Bold,
            color = DSOrange,
            modifier = Modifier.testTag("result-score"),
        )
        Text("击败全国 ${result.beatRate}% 的考生", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = DSAccent)
        Text("当前排名 #${result.rank}", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = DSBlue)
        Spacer(Modifier.weight(1f))
        Button(
            onClick = {
                appState.selectedTab.value = HomeTab.Exams
                appState.navigateTo(Route.Home)
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 32.dp)
                .testTag("result-back"),
            shape = MaterialTheme.shapes.extraLarge,
            colors = ButtonDefaults.buttonColors(containerColor = DSAccent),
        ) { Text("返回路线图", color = Color.White) }
    }
}
