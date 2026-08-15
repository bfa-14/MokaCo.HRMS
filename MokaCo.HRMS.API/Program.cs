using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Repository.Payroll;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Report;
using MokaCo.HRMS.Services.Workflow;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Api.Jobs;
using MokaCo.HRMS.Api.Controllers;
using System.Threading.RateLimiting;
using Quartz;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

// --- Configuration ---
var connectionString = builder.Configuration.GetConnectionString("MokaCo")
    ?? throw new InvalidOperationException("Missing connection string 'MokaCo'.");

var jwtOptions = builder.Configuration.GetSection("Jwt").Get<JwtOptions>()
    ?? throw new InvalidOperationException("Missing 'Jwt' configuration.");

// --- DI: infrastructure ---
builder.Services.AddSingleton<IDbConnectionFactory>(new SqlConnectionFactory(connectionString));
builder.Services.AddSingleton(jwtOptions);

// --- DI: repositories (Security) ---
builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IUserSignatureRepository, UserSignatureRepository>();
builder.Services.AddScoped<IRoleRepository, RoleRepository>();
builder.Services.AddScoped<IPermissionRepository, PermissionRepository>();
builder.Services.AddScoped<IRefreshTokenRepository, RefreshTokenRepository>();

// --- DI: repositories (Core) ---
builder.Services.AddScoped<ICurrencyRepository, CurrencyRepository>();
builder.Services.AddScoped<IExchangeRateRepository, ExchangeRateRepository>();
builder.Services.AddScoped<IDashboardRepository, DashboardRepository>();

// --- DI: repositories (HR) ---
builder.Services.AddScoped<IBranchRepository, BranchRepository>();
builder.Services.AddScoped<IDepartmentRepository, DepartmentRepository>();
builder.Services.AddScoped<IPositionRepository, PositionRepository>();
builder.Services.AddScoped<IComponentTypeRepository, ComponentTypeRepository>();
builder.Services.AddScoped<IEmployeeRepository, EmployeeRepository>();
builder.Services.AddScoped<ILeaveTypeRepository, LeaveTypeRepository>();
builder.Services.AddScoped<ISalaryComponentRepository, SalaryComponentRepository>();
builder.Services.AddScoped<IDocumentRepository, DocumentRepository>();
builder.Services.AddScoped<ILeaveLedgerRepository, LeaveLedgerRepository>();
builder.Services.AddScoped<ILeaveAccrualRepository, LeaveAccrualRepository>();

// --- DI: repositories (Attendance) ---
builder.Services.AddScoped<ISettingRepository, SettingRepository>();
builder.Services.AddScoped<ISystemRepository, SystemRepository>();
builder.Services.AddScoped<IDeviceRepository, DeviceRepository>();
builder.Services.AddScoped<IShiftRepository, ShiftRepository>();
builder.Services.AddScoped<IRosterRepository, RosterRepository>();
builder.Services.AddScoped<IIngestionRepository, IngestionRepository>();
builder.Services.AddScoped<IAttendanceRepository, AttendanceRepository>();
builder.Services.AddScoped<ICorrectionRepository, CorrectionRepository>();

// --- DI: repositories (Report) ---
builder.Services.AddScoped<IReportRepository, ReportRepository>();

// --- DI: repositories (Workflow) ---
builder.Services.AddScoped<IDefinitionRepository, DefinitionRepository>();
builder.Services.AddScoped<IRequestRepository, RequestRepository>();
builder.Services.AddScoped<IAttachmentRepository, AttachmentRepository>();
builder.Services.AddScoped<IExitPermissionRepository, ExitPermissionRepository>();
builder.Services.AddScoped<ILeaveRequestRepository, LeaveRequestRepository>();
builder.Services.AddScoped<ITipDistributionRepository, TipDistributionRepository>();
builder.Services.AddScoped<IShiftSwapRepository, ShiftSwapRepository>();
builder.Services.AddScoped<IOvertimeRepository, OvertimeRepository>();
builder.Services.AddScoped<IExpenseRepository, ExpenseRepository>();
builder.Services.AddScoped<IAvailabilityRepository, AvailabilityRepository>();
builder.Services.AddScoped<IOnboardingRepository, OnboardingRepository>();
builder.Services.AddScoped<ISeparationRepository, SeparationRepository>();
builder.Services.AddScoped<IPayrollAdjustmentRepository, PayrollAdjustmentRepository>();
builder.Services.AddScoped<ISalaryAdvanceRepository, SalaryAdvanceRepository>();
builder.Services.AddScoped<IWorkflowSupportRepository, WorkflowSupportRepository>();

// --- DI: repositories (Payroll) ---
builder.Services.AddScoped<IPayrollRepository, PayrollRepository>();

// --- DI: services (Security) ---
builder.Services.AddSingleton<IPasswordHasher, Argon2PasswordHasher>();
builder.Services.AddSingleton<IJwtTokenService, JwtTokenService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<IUserService, UserService>();
builder.Services.AddScoped<IUserSignatureService, UserSignatureService>();

// --- DI: services (Core) ---
builder.Services.AddScoped<ICurrencyService, CurrencyService>();
builder.Services.AddScoped<IExchangeRateService, ExchangeRateService>();
builder.Services.AddScoped<IDashboardService, DashboardService>();

// --- DI: services (HR) ---
builder.Services.AddScoped<IBranchService, BranchService>();
builder.Services.AddScoped<IDepartmentService, DepartmentService>();
builder.Services.AddScoped<IPositionService, PositionService>();
builder.Services.AddScoped<IComponentTypeService, ComponentTypeService>();
builder.Services.AddScoped<IEmployeeService, EmployeeService>();
builder.Services.AddScoped<ILeaveTypeService, LeaveTypeService>();
builder.Services.AddScoped<ISalaryComponentService, SalaryComponentService>();
builder.Services.AddScoped<IDocumentService, DocumentService>();
builder.Services.AddScoped<ILeaveLedgerService, LeaveLedgerService>();
builder.Services.AddScoped<ILeaveAccrualService, LeaveAccrualService>();

// --- DI: services (Attendance) ---
builder.Services.AddScoped<ISettingService, SettingService>();
builder.Services.AddScoped<IDeviceService, DeviceService>();
builder.Services.AddScoped<IShiftService, ShiftService>();
builder.Services.AddScoped<IRosterService, RosterService>();
builder.Services.AddScoped<IImportService, ImportService>();
builder.Services.AddScoped<IAttendanceService, AttendanceService>();
builder.Services.AddScoped<ICorrectionService, CorrectionService>();

// Machine pull: the server calling the terminal, as opposed to the iclock endpoint where it calls us.
// The LOCKS are a singleton and must stay one — they are what stops the timer and the "Pull now"
// button opening two sessions to the same machine, and a scoped registry would hand each caller its
// own semaphore and therefore lock nothing at all.
builder.Services.AddSingleton<DevicePullLocks>();
builder.Services.AddScoped<IMachinePullService, MachinePullService>();
builder.Services.AddHostedService<MachinePullWorker>();

// --- DI: services (Report) ---
builder.Services.AddScoped<IReportService, ReportService>();

// --- DI: services (Workflow) ---
builder.Services.AddScoped<IDefinitionService, DefinitionService>();
builder.Services.AddScoped<IRequestService, RequestService>();
builder.Services.AddScoped<IAttachmentService, AttachmentService>();
builder.Services.AddScoped<IExitPermissionService, ExitPermissionService>();
builder.Services.AddScoped<ILeaveRequestService, LeaveRequestService>();
builder.Services.AddScoped<IDecisionSignatureService, DecisionSignatureService>();
builder.Services.AddScoped<ITipDistributionService, TipDistributionService>();
builder.Services.AddScoped<IShiftSwapService, ShiftSwapService>();
builder.Services.AddScoped<IOvertimeService, OvertimeService>();
builder.Services.AddScoped<IExpenseService, ExpenseService>();
builder.Services.AddScoped<IAvailabilityService, AvailabilityService>();
builder.Services.AddScoped<IOnboardingService, OnboardingService>();
builder.Services.AddScoped<ISeparationService, SeparationService>();
builder.Services.AddScoped<IPayrollAdjustmentService, PayrollAdjustmentService>();
builder.Services.AddScoped<ISalaryAdvanceService, SalaryAdvanceService>();
builder.Services.AddScoped<IWorkflowSupportService, WorkflowSupportService>();

// --- DI: services (Payroll) ---
builder.Services.AddScoped<IPayrollService, PayrollService>();

// --- Scheduled jobs (Quartz.NET, in-memory RAMJobStore — no DB job store) ---
builder.Services.AddQuartz(q =>
{
    var accrualJobKey = new JobKey("MonthlyAccrualJob");
    q.AddJob<MonthlyAccrualJob>(opts => opts.WithIdentity(accrualJobKey));
    q.AddTrigger(t => t
        .ForJob(accrualJobKey)
        .WithIdentity("MonthlyAccrualTrigger")
        // seconds-first cron: 00:30 on day 1 of every month
        .WithCronSchedule("0 30 0 1 * ?"));

    // Attendance: process punches, mark absentees, reclassify approved leave.
    // The store is in-memory, so a run missed while the API was down is LOST, not caught up —
    // which is why /api/attendance/process and /mark-absentees are also exposed manually.
    var nightlyAttendanceJobKey = new JobKey("NightlyAttendanceJob");
    q.AddJob<NightlyAttendanceJob>(opts => opts.WithIdentity(nightlyAttendanceJobKey));
    q.AddTrigger(t => t
        .ForJob(nightlyAttendanceJobKey)
        .WithIdentity("NightlyAttendanceTrigger")
        // seconds-first cron: 01:00 every day
        .WithCronSchedule("0 0 1 * * ?"));
});
builder.Services.AddQuartzHostedService(opts => opts.WaitForJobsToComplete = true);

// --- Authentication (JWT) ---
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = jwtOptions.Issuer,
            ValidAudience = jwtOptions.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtOptions.SecretKey)),
            ClockSkew = TimeSpan.FromSeconds(30)
        };

        // THE HUB'S TOKEN ARRIVES IN THE QUERY STRING, and only the hub's.
        //
        // WebSockets cannot carry custom headers from a browser — the WebSocket API has no way to
        // set Authorization — so SignalR's standard pattern is ?access_token=. That is a real
        // trade: query strings land in server logs and browser history in a way headers do not.
        // It is scoped as tightly as possible: the token is read ONLY for the hub path, so every
        // ordinary API call keeps using the Authorization header and gains no new exposure.
        options.Events = new JwtBearerEvents
        {
            OnMessageReceived = context =>
            {
                var accessToken = context.Request.Query["access_token"];
                var path = context.HttpContext.Request.Path;
                if (!string.IsNullOrEmpty(accessToken) && path.StartsWithSegments("/hubs/live"))
                    context.Token = accessToken;

                return Task.CompletedTask;
            }
        };
    });

// --- Authorization (permission policies) ---
//
// THE FALLBACK IS THE DEFAULT ANSWER. Without it, an endpoint carrying no [Authorize] and no
// [HasPermission] is simply OPEN — protection is opt-in, and forgetting the attribute on one new
// action is a silent hole rather than a compile error. With it, authentication is the floor and an
// endpoint has to say [AllowAnonymous] out loud to be public.
//
// It applies only where NOTHING else is specified, so every existing [Authorize] and permission
// policy is untouched. Four things are deliberately public and now say so:
//   - AuthController login + refresh ([AllowAnonymous]) — you cannot hold a token before logging in;
//   - IclockController ([AllowAnonymous] on the class) — the fingerprint terminals speak a fixed
//     ZKTeco protocol and cannot send a bearer token; they are gated by serial + rate limiter;
//   - AttendanceIngestion punch ([AllowAnonymous]) — [DeviceApiKey] is an action FILTER, not an
//     authentication scheme, so the fallback would demand a JWT the device does not have;
//   - the Development-only OpenAPI/Scalar endpoints.
builder.Services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>();
builder.Services.AddAuthorization(options =>
{
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});

// --- Rate limiting: the fingerprint terminals' push endpoints only ---
//
// Scoped to /iclock/* by the [EnableRateLimiting] attribute on IclockController, because that is
// the one part of the API that is not behind a JWT: it is reachable by anyone who can guess a
// registered serial, and the serial is printed on the back of the machine. Everything else in the
// API is protected by having to log in first, and a limiter there would only ever punish real users.
//
// PARTITIONED BY SERIAL, so one terminal (or one leaked serial) cannot starve the others. Falls
// back to the remote IP when there is no SN — a caller that has not even said who it claims to be
// still must not get an unlimited number of guesses.
//
// The ceiling is deliberately generous. A real terminal with Realtime=1 sends one small request per
// punch plus a command poll every few seconds; a busy door at shift change might produce a few
// dozen requests in a minute, and a device flushing a backlog after an outage produces a burst.
// This is sized to be invisible to all of that and to still cap a flood.
builder.Services.AddRateLimiter(options =>
{
    // 429 is not in a fingerprint terminal's vocabulary. 503 is a "try later" it already handles by
    // keeping the batch and retrying — which is exactly what we want it to do, since a throttled
    // punch must not be treated by the device as delivered.
    options.RejectionStatusCode = StatusCodes.Status503ServiceUnavailable;

    options.AddPolicy(IclockController.RateLimitPolicy, context =>
    {
        var serial = context.Request.Query["SN"].ToString();
        var partition = string.IsNullOrWhiteSpace(serial)
            ? $"ip:{context.Connection.RemoteIpAddress}"
            : $"sn:{serial}";

        return RateLimitPartition.GetFixedWindowLimiter(partition, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 240,                     // ~4/second sustained, per terminal
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0                         // refuse immediately; the device's own retry IS the queue
        });
    });
});

// --- CORS for the React front end (adjust origin) ---
const string CorsPolicy = "MokaCoFront";
builder.Services.AddCors(o => o.AddPolicy(CorsPolicy, p =>
    p.WithOrigins("http://localhost:5173")   // Vite dev server; change as needed
     .AllowAnyHeader()
     .AllowAnyMethod()
     // Required by SignalR: its JS client sets withCredentials on the negotiate request, and a
     // response without Access-Control-Allow-Credentials fails CORS before the socket is ever
     // opened. Legal here only because the origin is named explicitly — the browser refuses this
     // combined with a wildcard origin, which is the rule that keeps it safe.
     .AllowCredentials()));

// --- Live updates (SignalR): signals only, never data ---
builder.Services.AddSignalR();
builder.Services.AddSingleton<ILiveNotifier, LiveNotifier>();

builder.Services.AddControllers();
builder.Services.AddOpenApi();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    // AllowAnonymous because the authorization fallback would otherwise demand a token to read the
    // documentation — and the documentation is how you find out how to get one. Development only.
    app.MapOpenApi().AllowAnonymous();          // serves the spec at /openapi/v1.json
    app.MapScalarApiReference().AllowAnonymous(); // interactive UI at /scalar/v1
}

// NOTE FOR THE FINGERPRINT TERMINALS: this redirects plain HTTP to HTTPS with a 307, and ZKTeco
// firmware does not reliably follow redirects — a terminal configured against port 80 can sit there
// "connected" and never deliver a punch. If the device turns out not to speak TLS, the fix is to
// terminate TLS in front of the API (IIS/nginx) and let it forward on HTTP, NOT to drop this line:
// the serial and every punch travel in clear text, and the serial is the only credential this
// protocol has.
// /iclock is exempt because the terminals speak plain HTTP on the LAN and do not follow 307s; every
// other endpoint keeps the redirect.
app.UseWhen(
    ctx => !ctx.Request.Path.StartsWithSegments("/iclock"),
    branch => branch.UseHttpsRedirection());
app.UseCors(CorsPolicy);

// Before authentication on purpose: a flood should be refused at the door, not after we have done
// the work of trying to identify it. Only endpoints carrying [EnableRateLimiting] are affected —
// there is no global limiter, so every JWT-protected endpoint is untouched.
app.UseRateLimiter();

app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHub<LiveHub>("/hubs/live");

// The one line an installer needs: exactly what to type into a terminal's Cloud Server / ADMS
// screen. Both halves are RESOLVED, never assumed — the LAN IP is per-machine and changes with the
// DHCP lease, and the port is whatever the profile actually bound. A guessed address here is
// indistinguishable from a dead terminal, which is the failure this line exists to prevent.
// Registered on ApplicationStarted because the server's real addresses do not exist until then.
app.Lifetime.ApplicationStarted.Register(() =>
{
    var bound = app.Services.GetRequiredService<IServer>()
        .Features.Get<IServerAddressesFeature>()?.Addresses ?? [];

    // "http://0.0.0.0:5078" / "http://[::]:5078" / "http://localhost:5078" — all we want is the port.
    var httpPort = bound
        .Select(address => Uri.TryCreate(address, UriKind.Absolute, out var uri) ? uri : null)
        .FirstOrDefault(uri => uri is not null && uri.Scheme == Uri.UriSchemeHttp)?.Port;

    // Every operational IPv4 that is not loopback — on a machine with Wi-Fi and Ethernet both up,
    // the installer needs to be told which addresses exist rather than handed one at random.
    var lanIPs = NetworkInterface.GetAllNetworkInterfaces()
        .Where(nic => nic.OperationalStatus == OperationalStatus.Up
                      && nic.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .SelectMany(nic => nic.GetIPProperties().UnicastAddresses)
        .Select(unicast => unicast.Address)
        .Where(ip => ip.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ip))
        .Select(ip => ip.ToString())
        .Distinct()
        .ToArray();

    var target = httpPort is null
        ? "no plain-HTTP binding — the terminals cannot reach this instance"
        : lanIPs.Length == 0
            ? $"http://<this machine's LAN IP>:{httpPort}"
            : string.Join(" or ", lanIPs.Select(ip => $"http://{ip}:{httpPort}"));

    app.Logger.LogInformation(
        "iclock receiver listening — point terminals at {Target} (device Cloud Server / ADMS " +
        "setting), serial must be registered on Attendance > Devices.", target);
});

app.Run();
