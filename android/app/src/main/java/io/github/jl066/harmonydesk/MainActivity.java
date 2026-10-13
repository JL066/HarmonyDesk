package io.github.jl066.harmonydesk;

import android.app.*;
import android.os.*;
import android.content.*;
import android.content.res.Configuration;
import android.graphics.*;
import android.view.*;
import android.widget.*;
import android.text.InputType;

/** Single remote session; resizing replaces the video surface, never the transport. */
public final class MainActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private SecureSettings settings;
    private ClipboardBridge clipboard;
    private LinearLayout root;
    private TextView status;
    private EditText server, relay, serverKey, peer, password;
    private CheckBox viewOnly, rememberPassword;
    private Spinner routeMode;
    private Button clipboardButton;
    private String clipboardMessage="剪贴板同步已关闭";
    private static final int[] ROUTE_POLICIES={2,1,0};
    private long lastInputReportAt, sentMouseEvents, sentKeyEvents;
    private TextureView texture;
    private RemoteInputView input;
    private FloatingMousePanel mousePanel;
    private VideoDecoder decoder;
    private Surface outputSurface;
    private SurfaceTexture decoderTexture, pendingTexture;
    private boolean decoderStopping, releaseDecoderTexture;
    private Object backCallback;
    private boolean session, paused, destroyed, interactive;
    private int modeIndex;
    private long connectingSince, connectClickedAt;
    private boolean readyTimeReported, firstImageReported;
    private final InputSink sink = new InputSink() {
        public void mouse(int mask, int x, int y) { if (interactive) {NativeCore.mouse(mask,x,y);sentMouseEvents++;} }
        public void key(int kind, int code, boolean down, int[] mods) { if (interactive) {NativeCore.key(kind,code,down,mods);sentKeyEvents++;} }
        public void text(String text) { if (interactive) NativeCore.text(text); }
        public void control(int code) { if (interactive) NativeCore.control(code); }
    };
    private final Runnable poll = new Runnable() {
        public void run() {
            if (!session || destroyed) return;
            int state = NativeCore.status();
            // Native READY also covers lookup outcomes. A real display is required for input.
            boolean ready = state == 1 && NativeCore.width() > 0 && NativeCore.height() > 0;
            boolean windowFocused = hasWindowFocus();
            boolean readOnly = viewOnly.isChecked();
            boolean nextInteractive = ready && !paused && windowFocused && !readOnly;
            if (interactive && !nextInteractive) releaseInput();
            interactive = nextInteractive;
            if (input != null) input.setViewOnly(!interactive);
            if (ready) {
                if(!readyTimeReported){
                    readyTimeReported=true;
                    android.util.Log.i("RemoteDeskPerf","session_ready_ms="+(SystemClock.elapsedRealtime()-connectingSince));
                }
                String inputState = readOnly ? "只看画面" : paused ? "操作已暂停：应用在后台"
                        : !windowFocused ? "操作已暂停：窗口未获得焦点，请关闭系统浮层后返回" : "可操作";
                status.setText("已连接 · "+routeLabel(NativeCore.routeKind())+" · " + NativeCore.width() + " × " + NativeCore.height()+"\n"+inputState+" · "+clipboardMessage);
                if(SystemClock.elapsedRealtime()-lastInputReportAt>=5000){
                    android.util.Log.i("RemoteDeskPerf","route="+NativeCore.routeKind()+" input_allowed="+(interactive?1:0)+" paused="+(paused?1:0)+" window_focus="+(windowFocused?1:0)+" view_only="+(readOnly?1:0)+" mouse_sent="+sentMouseEvents+" key_sent="+sentKeyEvents);
                    sentMouseEvents=0;sentKeyEvents=0;lastInputReportAt=SystemClock.elapsedRealtime();
                }
                if (input != null) input.setRemoteSize(NativeCore.width(),NativeCore.height());
                if (interactive && hasWindowFocus()) clipboard.start(); else clipboard.stop();
            } else if (state == 3 || (state == 0) || SystemClock.elapsedRealtime()-connectingSince > 30000) {
                android.util.Log.i("RemoteDeskSession","event=connection_end state="+state+" paused="+(paused?1:0));
                String message = state == 3 ? "连接失败，请检查服务器、设备 ID 和密码" : "连接未完成或已断开";
                endSession(); new AlertDialog.Builder(MainActivity.this).setMessage(message).setPositiveButton("确定",null).show(); return;
            } else status.setText("正在连接…");
            main.postDelayed(this,500);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        try { NativeCore.init(); settings = new SecureSettings(this); clipboard = new ClipboardBridge(this); }
        catch (Throwable e) {
            android.util.Log.e("HarmonyDeskStartup", "Client initialization failed", e);
            TextView failure = new TextView(this); failure.setText("无法加载客户端组件，请重新安装完整的 ARM64 安装包。"); setContentView(failure); return;
        }
        clipboard.setEnabled(Boolean.parseBoolean(read("clipboardEnabled","false")));
        clipboard.setStatusListener(message->{
            clipboardMessage=message;
            if(clipboardButton!=null)clipboardButton.setText(clipboard.isEnabled()?"剪贴板：开":"剪贴板：关");
        });
        showConnection();
    }
    private int dp(int n) { return Math.round(n*getResources().getDisplayMetrics().density); }
    private TextView text(String value,int size) { TextView v=new TextView(this);v.setText(value);v.setTextColor(Color.WHITE);v.setTextSize(size);v.setPadding(dp(8),dp(8),dp(8),dp(8));return v; }
    private Button button(String label,Runnable action) { Button b=new Button(this);b.setText(label);b.setAllCaps(false);b.setFocusable(false);b.setOnClickListener(v->action.run());return b; }
    private void base() {
        root = new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(Color.rgb(17,25,32));
        root.setOnApplyWindowInsetsListener((v,insets)->{
            if(Build.VERSION.SDK_INT>=30) {
                Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
                Insets ime=insets.getInsets(WindowInsets.Type.ime());v.setPadding(bars.left,bars.top,bars.right,Math.max(bars.bottom,ime.bottom));
            } else v.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());
            return insets;
        });setContentView(root);root.requestApplyInsets();
    }
    private String read(String key,String fallback) { try{return settings.get(key,fallback);}catch(RuntimeException e){return fallback;} }
    private EditText field(LinearLayout box,String label,String value,boolean secret) {
        box.addView(text(label,14));EditText v=new EditText(this);v.setSingleLine(true);v.setTextColor(Color.WHITE);v.setText(value);
        v.setInputType(secret?InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD:InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        v.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);box.addView(v,new LinearLayout.LayoutParams(-1,dp(52)));return v;
    }
    private void showConnection() {
        base();ScrollView scroll=new ScrollView(this);root.addView(scroll,new LinearLayout.LayoutParams(-1,-1));
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(20),dp(16),dp(20),dp(24));scroll.addView(box);
        box.addView(text("RemoteDesk",30));box.addView(text("Android 远程桌面 · 使用现有服务器",15));
        server=field(box,"ID 服务器",read("server",""),false);relay=field(box,"中继服务器（可留空）",read("relay",""),false);
        serverKey=field(box,"服务器 Key",read("serverKey",""),true);peer=field(box,"远程设备 ID / 局域网地址",read("peer",""),false);
        password=field(box,"远程密码",read("password",""),true);
        box.addView(text("连接方式",14));
        routeMode=new Spinner(this);
        ArrayAdapter<String> routes=new ArrayAdapter<>(this,android.R.layout.simple_spinner_item,new String[]{"自动：局域网直连，外网中继","始终使用中继","优先直连（含外网打洞）"});
        routes.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);routeMode.setAdapter(routes);
        String savedRoute=read("routePolicy","2");
        routeMode.setSelection("1".equals(savedRoute)?1:"0".equals(savedRoute)?2:0);
        box.addView(routeMode,new LinearLayout.LayoutParams(-1,dp(52)));
        box.addView(text("同一局域网优先直连，不可用时回退中继。手动填写 IP 地址时始终直连。",12));
        viewOnly=new CheckBox(this);viewOnly.setText("只看画面");box.addView(viewOnly);
        rememberPassword=new CheckBox(this);rememberPassword.setText("在本机加密保存密码");rememberPassword.setChecked(!read("password","").isEmpty());box.addView(rememberPassword);
        box.addView(button("连接电脑",this::connect));
        box.addView(text("直接触控始终可用；连接后可随时呼出浮动鼠标或键盘。",14));
    }
    private void connect() {
        connectClickedAt=SystemClock.elapsedRealtime();
        readyTimeReported=false;firstImageReported=false;
        String id=peer.getText().toString().trim();
        sentMouseEvents=0;sentKeyEvents=0;lastInputReportAt=0;
        if(id.isEmpty()){peer.setError("请输入设备 ID 或地址");return;}
        try {
            settings.put("server",server.getText().toString().trim());settings.put("relay",relay.getText().toString().trim());
            settings.put("serverKey",serverKey.getText().toString().trim());settings.put("peer",id);settings.put("routePolicy",Integer.toString(selectedRoutePolicy()));
            if(rememberPassword.isChecked())settings.put("password",password.getText().toString());else settings.remove("password");
        } catch(RuntimeException e){new AlertDialog.Builder(this).setMessage("本机安全存储不可用，未保存连接资料。").setPositiveButton("确定",null).show();return;}
        long savedAt=SystemClock.elapsedRealtime();
        android.util.Log.i("RemoteDeskPerf","settings_save_ms="+(savedAt-connectClickedAt)+" route_policy="+selectedRoutePolicy());
        int configured=NativeCore.configure(server.getText().toString().trim(),relay.getText().toString().trim(),selectedRoutePolicy()==1,serverKey.getText().toString().trim());
        if(configured!=0 && !id.contains("." ) && !id.contains(":")){server.setError("请输入有效 ID 服务器");return;}
        if(NativeCore.setRoutePolicy(selectedRoutePolicy())!=0){Toast.makeText(this,"连接方式设置失败",Toast.LENGTH_LONG).show();return;}
        long configuredAt=SystemClock.elapsedRealtime();
        android.util.Log.i("RemoteDeskPerf","configure_ms="+(configuredAt-savedAt));
        try{startForegroundService(new Intent(this,SessionService.class));}
        catch(RuntimeException e){Toast.makeText(this,"无法启动连接服务，请重新打开应用后重试",Toast.LENGTH_LONG).show();return;}
        if(NativeCore.connect(id,password.getText().toString())<0){stopService(new Intent(this,SessionService.class));Toast.makeText(this,"无法发起连接",Toast.LENGTH_LONG).show();return;}
        connectingSince=SystemClock.elapsedRealtime();
        android.util.Log.i("RemoteDeskPerf","connect_dispatch_ms="+(connectingSince-configuredAt));
        session=true;updateBackCallback();showSession();main.post(poll);
    }
    private void showSession() {
        modeIndex=0;
        base();status=text("正在连接…",14);root.addView(status);
        FrameLayout desktop=new FrameLayout(this);desktop.setBackgroundColor(Color.BLACK);root.addView(desktop,new LinearLayout.LayoutParams(-1,0,1));
        texture=new TextureView(this);desktop.addView(texture,new FrameLayout.LayoutParams(-1,-1));
        input=new RemoteInputView(this,sink);input.setCursorVisible(true);input.setViewOnly(true);desktop.addView(input,new FrameLayout.LayoutParams(-1,-1));
        input.onViewportChanged=this::transformVideo;
        texture.setSurfaceTextureListener(new TextureView.SurfaceTextureListener(){
            public void onSurfaceTextureAvailable(SurfaceTexture t,int w,int h){startDecoder(t);}
            public void onSurfaceTextureSizeChanged(SurfaceTexture t,int w,int h){transformVideo();}
            public boolean onSurfaceTextureDestroyed(SurfaceTexture t){
                if(pendingTexture==t)pendingTexture=null;
                if(decoderTexture==t){releaseDecoderTexture=true;stopDecoder();return false;}
                return true;
            }
            public void onSurfaceTextureUpdated(SurfaceTexture t){
                if(session&&!firstImageReported){
                    firstImageReported=true;
                    android.util.Log.i("RemoteDeskPerf","first_image_ms="+(SystemClock.elapsedRealtime()-connectClickedAt));
                }
            }
        });
        mousePanel=new FloatingMousePanel(this,sink,input);
        FrameLayout.LayoutParams panel=new FrameLayout.LayoutParams(dp(230),dp(190),Gravity.BOTTOM|Gravity.END);panel.setMargins(dp(8),dp(8),dp(8),dp(8));desktop.addView(mousePanel,panel);mousePanel.setVisibility(View.GONE);
        HorizontalScrollView tools=new HorizontalScrollView(this);LinearLayout row=new LinearLayout(this);tools.addView(row);root.addView(tools,new LinearLayout.LayoutParams(-1,dp(56)));
        row.addView(button("键盘",()->input.showKeyboard()));row.addView(button("收键盘",()->input.hideKeyboard()));
        row.addView(button("鼠标",()->{mousePanel.setVisibility(mousePanel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE);input.requestFocus();}));
        row.addView(button("显示",()->{modeIndex=(modeIndex+1)%3;input.setDisplayMode(Viewport.Mode.values()[modeIndex]);}));
        clipboardButton=button(clipboard.isEnabled()?"剪贴板：开":"剪贴板：关",()->{
            boolean enable=!clipboard.isEnabled();
            try{settings.put("clipboardEnabled",Boolean.toString(enable));}
            catch(RuntimeException e){Toast.makeText(this,"无法保存剪贴板开关，请重试",Toast.LENGTH_SHORT).show();return;}
            clipboard.setEnabled(enable);
            Toast.makeText(this,clipboardMessage,Toast.LENGTH_SHORT).show();
        });row.addView(clipboardButton);
        row.addView(button("Ctrl+C",()->chord('c',4)));row.addView(button("Ctrl+V",()->chord('v',4)));
        row.addView(button("Esc",()->sink.control(8)));row.addView(button("断开",this::endSession));
        input.post(()->input.requestFocus());
    }
    private int selectedRoutePolicy(){return ROUTE_POLICIES[routeMode.getSelectedItemPosition()];}
    private String routeLabel(int kind){return kind==1?"局域网直连":kind==2?"中继":kind==3?"直连":"选择线路中";}
    private void chord(int c,int modifier){sink.key(2,modifier,true,new int[]{modifier});sink.key(1,c,true,new int[]{modifier});sink.key(1,c,false,new int[]{modifier});sink.key(2,modifier,false,new int[0]);}
    private void transformVideo(){if(texture==null||input==null||texture.getWidth()==0||texture.getHeight()==0)return;Viewport v=input.viewport;Matrix m=new Matrix();m.setScale((float)(v.renderedWidth()/texture.getWidth()),(float)(v.renderedHeight()/texture.getHeight()));m.postTranslate((float)v.offsetX(),(float)v.offsetY());texture.setTransform(m);}
    private void startDecoder(SurfaceTexture surfaceTexture){
        pendingTexture=surfaceTexture;
        if(decoder!=null)stopDecoder();else startPendingDecoder();
    }
    private void startPendingDecoder(){
        if(destroyed||!session||pendingTexture==null||decoder!=null)return;
        decoderTexture=pendingTexture;pendingTexture=null;
        outputSurface=new Surface(decoderTexture);
        decoder=new VideoDecoder(outputSurface,new VideoDecoder.Listener(){
            public void onSize(int w,int h){if(input!=null){input.setRemoteSize(w,h);transformVideo();}}
            public void onError(String message){if(session)status.setText("画面解码重试中，请保持连接");}
        });decoder.start();
    }
    private void stopDecoder(){
        if(decoder==null||decoderStopping)return;
        decoderStopping=true;
        // A codec can take longer than the bounded stop wait. Keep both surfaces
        // alive and defer the replacement until its worker has actually exited.
        decoder.stop(()->{
            if(outputSurface!=null)outputSurface.release();
            if(releaseDecoderTexture&&decoderTexture!=null)decoderTexture.release();
            outputSurface=null;decoderTexture=null;decoder=null;
            decoderStopping=false;releaseDecoderTexture=false;
            startPendingDecoder();
        });
    }
    private void releaseInput(){if(input!=null)input.releaseAll();interactive=false;if(clipboard!=null)clipboard.stop();}
    private void endSession(){releaseInput();session=false;updateBackCallback();pendingTexture=null;main.removeCallbacks(poll);stopDecoder();NativeCore.disconnect();stopService(new Intent(this,SessionService.class));clipboard.resetSession();clipboardButton=null;input=null;texture=null;mousePanel=null;if(!destroyed)showConnection();}
    @Override public void onWindowFocusChanged(boolean focus){super.onWindowFocusChanged(focus);if(!focus)releaseInput();else if(session&&input!=null)input.requestFocus();}
    @Override protected void onPause(){releaseInput();paused=true;android.util.Log.i("RemoteDeskSession","event=pause session="+(session?1:0));super.onPause();}
    @Override protected void onResume(){super.onResume();paused=false;android.util.Log.i("RemoteDeskSession","event=resume session="+(session?1:0));if(session&&input!=null)input.requestFocus();}
    @Override public void onConfigurationChanged(Configuration config){super.onConfigurationChanged(config);if(input!=null)input.post(this::transformVideo);if(root!=null)root.requestApplyInsets();}
    private void confirmDisconnect(){new AlertDialog.Builder(this).setMessage("断开当前远程连接？").setNegativeButton("继续使用",null).setPositiveButton("断开",(d,w)->endSession()).show();}
    private void updateBackCallback(){
        if(Build.VERSION.SDK_INT<33)return;
        if(backCallback!=null){getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback((android.window.OnBackInvokedCallback)backCallback);backCallback=null;}
        if(session&&!destroyed){
            android.window.OnBackInvokedCallback callback=this::confirmDisconnect;
            backCallback=callback;
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,callback);
        }
    }
    // API 33+ uses the platform callback above; this override serves API 26-32 only.
    @android.annotation.SuppressLint("GestureBackNavigation")
    @Override public void onBackPressed(){if(session)confirmDisconnect();else super.onBackPressed();}
    @Override protected void onDestroy(){destroyed=true;main.removeCallbacksAndMessages(null);if(session)endSession();super.onDestroy();}
}
