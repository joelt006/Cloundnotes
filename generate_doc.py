from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

doc = Document()

# ── Page margins ──────────────────────────────────────────────────────────────
for section in doc.sections:
    section.top_margin    = Inches(1)
    section.bottom_margin = Inches(1)
    section.left_margin   = Inches(1.2)
    section.right_margin  = Inches(1.2)

# ── Styles ────────────────────────────────────────────────────────────────────
def heading1(text):
    p = doc.add_heading(text, level=1)
    p.runs[0].font.color.rgb = RGBColor(0x1F, 0x49, 0x7D)
    return p

def heading2(text):
    p = doc.add_heading(text, level=2)
    p.runs[0].font.color.rgb = RGBColor(0x2E, 0x74, 0xB5)
    return p

def body(text):
    p = doc.add_paragraph(text)
    p.runs[0].font.size = Pt(11)
    return p

def code_block(text):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Inches(0.3)
    shading = OxmlElement('w:pPr')
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), 'F2F2F2')
    shading.append(shd)
    p._p.insert(0, shading)
    run = p.add_run(text)
    run.font.name = 'Courier New'
    run.font.size = Pt(9.5)
    run.font.color.rgb = RGBColor(0x1E, 0x1E, 0x1E)
    return p

def note(text):
    p = doc.add_paragraph(text)
    p.paragraph_format.left_indent = Inches(0.3)
    run = p.runs[0]
    run.font.size = Pt(10)
    run.font.italic = True
    run.font.color.rgb = RGBColor(0x60, 0x60, 0x60)
    return p

# ══════════════════════════════════════════════════════════════════════════════
# TITLE
# ══════════════════════════════════════════════════════════════════════════════
title = doc.add_heading('CloudNotes — Azure Deployment Commands', 0)
title.alignment = WD_ALIGN_PARAGRAPH.CENTER
title.runs[0].font.color.rgb = RGBColor(0x1F, 0x49, 0x7D)
doc.add_paragraph('TUKE Cloud Computing Exam — sk1').alignment = WD_ALIGN_PARAGRAPH.CENTER
doc.add_paragraph()

# ══════════════════════════════════════════════════════════════════════════════
# 1. FIRST TIME SETUP
# ══════════════════════════════════════════════════════════════════════════════
heading1('1. First Time Setup')
body('Run these commands once before the first deployment.')
doc.add_paragraph()

heading2('Navigate to project folder')
code_block('cd ~/exam/sk1')

heading2('Show config template')
code_block('cat .env.example')

heading2('Create config file')
code_block('cp .env.example .env')
note('Edit .env and fill in your Azure and database values.')

heading2('Make scripts executable')
code_block('chmod +x *.sh')

heading2('Login to Azure')
code_block('az login')
note('Opens browser for authentication. Only needed once per session.')

heading2('Start Docker')
code_block('sudo service docker start')
note('Required in WSL before building images.')

# ══════════════════════════════════════════════════════════════════════════════
# 2. DEPLOY
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('2. Deploy Everything to Azure')
body('One command creates all Azure resources and deploys all 3 containers.')
doc.add_paragraph()

code_block('./prepare-app.sh')

doc.add_paragraph()
body('This script does the following in order:')
items = [
    'Creates Azure Resource Group',
    'Creates Azure Container Registry (ACR)',
    'Builds the Docker image locally',
    'Pushes the image to ACR',
    'Creates Azure Storage Account',
    'Creates 3 Azure File shares (caddy-data, caddy-config, postgres-data)',
    'Uploads Caddyfile to Azure Files',
    'Generates ACI JSON configuration',
    'Deploys 3 containers (Caddy + Flask + PostgreSQL)',
    'Waits for all containers to reach Running state',
]
for item in items:
    p = doc.add_paragraph(f'• {item}')
    p.paragraph_format.left_indent = Inches(0.3)
    p.runs[0].font.size = Pt(11)

# ══════════════════════════════════════════════════════════════════════════════
# 3. CHECK STATUS
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('3. Check Container Status')

heading2('Show all 3 containers and their state')
code_block(
    'az container show -g cloudnotes-rg -n cloudnotes-group \\\n'
    '  --query "containers[*].{name:name,state:instanceView.currentState.state}" -o table'
)
note('Expected output: caddy, backend, db — all showing Running.')

heading2('Show restart counts (proves auto-restart works)')
code_block(
    'az container show -g cloudnotes-rg -n cloudnotes-group \\\n'
    '  --query "containers[*].{name:name,restartCount:instanceView.restartCount}" -o table'
)

heading2('Show persistent storage shares')
code_block('az storage share list --account-name cloudnotesjoelsa -o table')
note('Shows: caddy-data, caddy-config, postgres-data')

# ══════════════════════════════════════════════════════════════════════════════
# 4. LOGS
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('4. View Logs (Access Logs from Internet)')

heading2('Caddy logs — shows HTTPS certificate + all requests')
code_block('az container logs -g cloudnotes-rg -n cloudnotes-group --container-name caddy')

heading2('Caddy logs — live stream (refresh browser to see requests appear)')
code_block('az container logs -g cloudnotes-rg -n cloudnotes-group --container-name caddy --follow')

heading2('Flask backend logs')
code_block('az container logs -g cloudnotes-rg -n cloudnotes-group --container-name backend')

heading2('PostgreSQL logs')
code_block('az container logs -g cloudnotes-rg -n cloudnotes-group --container-name db')

# ══════════════════════════════════════════════════════════════════════════════
# 5. VERIFY APP
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('5. Verify Application')

heading2('Health check endpoint')
code_block('curl https://cloudnotes-joel.germanywestcentral.azurecontainer.io/api/health')
note('Expected: {"status": "healthy", "database": "connected"}')

heading2('Open in browser')
code_block('https://cloudnotes-joel.germanywestcentral.azurecontainer.io')
note('Click the padlock → Certificate is valid → Issued by: Let\'s Encrypt')

# ══════════════════════════════════════════════════════════════════════════════
# 6. BACKUP
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('6. Backup Database')

heading2('Run backup')
code_block('cd ~/exam/sk1\n./backup.sh')
body('This script:')
backup_steps = [
    'Runs pg_dump inside the db container via az container exec',
    'Saves the dump to the postgres-data Azure Files share (/backup)',
    'Downloads the file to your local machine',
    'Compresses it with gzip',
    'Deletes the remote file from Azure Files',
]
for step in backup_steps:
    p = doc.add_paragraph(f'• {step}')
    p.paragraph_format.left_indent = Inches(0.3)
    p.runs[0].font.size = Pt(11)

heading2('Show saved backup files')
code_block('ls backups/')
note('Files are saved as: cloudnotes_backup_YYYYMMDD_HHMMSS.sql.gz')

# ══════════════════════════════════════════════════════════════════════════════
# 7. SHOW SOURCE FILES
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('7. Show Source Files (for Professor)')

heading2('List all project files')
code_block('ls ~/exam/sk1/')

heading2('Show .gitignore — secrets excluded from git')
code_block('cat ~/exam/sk1/.gitignore')
note('.env is listed here — passwords never committed to git.')

heading2('Show deployment script with line numbers')
code_block('cat -n ~/exam/sk1/prepare-app.sh')

heading2('Show backup script')
code_block('cat -n ~/exam/sk1/backup.sh')

heading2('Show removal script')
code_block('cat -n ~/exam/sk1/remove-app.sh')

heading2('Show Flask application code')
code_block('cat -n ~/exam/sk1/backend/app.py')

heading2('Show Dockerfile')
code_block('cat -n ~/exam/sk1/backend/Dockerfile')

# ══════════════════════════════════════════════════════════════════════════════
# 8. REDEPLOY AFTER CODE CHANGE
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('8. Redeploy After Code Change')
body('If you modify any source file, rebuild and redeploy with:')
doc.add_paragraph()
code_block('sudo service docker start   # make sure Docker is running\n./prepare-app.sh           # rebuilds image, pushes to ACR, redeploys')
note('The script skips already-existing Azure resources (ACR, storage, shares) — only rebuilds what changed.')

# ══════════════════════════════════════════════════════════════════════════════
# 9. AFTER LAPTOP RESTART
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('9. After Laptop Restart')
body('The containers keep running on Azure. Your laptop being off does not affect them.')
doc.add_paragraph()

heading2('Login again if session expired')
code_block('az login')

heading2('Verify containers are still running')
code_block(
    'az container show -g cloudnotes-rg -n cloudnotes-group \\\n'
    '  --query "containers[*].{name:name,state:instanceView.currentState.state}" -o table'
)
note('App is still at https://cloudnotes-joel.germanywestcentral.azurecontainer.io — no restart needed.')

# ══════════════════════════════════════════════════════════════════════════════
# 10. CLEANUP
# ══════════════════════════════════════════════════════════════════════════════
doc.add_page_break()
heading1('10. Remove Everything (Do This Last)')
body('Deletes all Azure resources: containers, registry, storage, everything.')
doc.add_paragraph()
code_block('./remove-app.sh')
note('Type "yes" when prompted to confirm. Takes 2-3 minutes. Cannot be undone.')

# ══════════════════════════════════════════════════════════════════════════════
# SAVE
# ══════════════════════════════════════════════════════════════════════════════
doc.save('/home/ambad/exam/sk1/CloudNotes_Commands.docx')
print('Done: CloudNotes_Commands.docx')
