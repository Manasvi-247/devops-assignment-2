import React, { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  App as AntApp, Avatar, Button, ConfigProvider, Form, Input, Modal,
  Progress, Select, Tag, Tooltip,
} from 'antd'
import { ArrowRightOutlined, DeleteOutlined, PlusOutlined } from '@ant-design/icons'
import './styles.css'

const API = '/api'
const COLUMNS = [
  { key: 'TODO', label: 'To do' },
  { key: 'IN_PROGRESS', label: 'In progress' },
  { key: 'DONE', label: 'Done' },
]
const NEXT = { TODO: 'IN_PROGRESS', IN_PROGRESS: 'DONE', DONE: 'TODO' }
const PRIORITY = {
  HIGH: { color: '#ce4257', label: 'High' },
  MEDIUM: { color: '#d9822b', label: 'Medium' },
  LOW: { color: '#0e9b8a', label: 'Low' },
}

const initials = (name) =>
  (name || '?').split(' ').map((p) => p[0]).slice(0, 2).join('').toUpperCase()

function Card({ task, onAdvance, onDelete }) {
  const [moved, setMoved] = useState(false)
  const priority = PRIORITY[task.priority] || PRIORITY.LOW

  const advance = async () => {
    setMoved(true)
    await onAdvance(task)
    setTimeout(() => setMoved(false), 200)
  }

  return (
    <article className={`card ${task.priority.toLowerCase()} ${moved ? 'moved' : ''}`}>
      <div className="card-title">{task.title}</div>
      {task.description ? <p className="card-desc">{task.description}</p> : null}
      <div className="card-foot">
        <Avatar size={22} style={{ background: '#5b4bd6', fontSize: 10 }}>
          {initials(task.assignee)}
        </Avatar>
        <span className="who">{(task.assignee || '').split(' ')[0]}</span>
        <Tag bordered={false} color={priority.color} style={{ marginInlineEnd: 0 }}>
          {priority.label}
        </Tag>
        <span className="spacer" />
        <Tooltip title={`Move to ${COLUMNS.find((c) => c.key === NEXT[task.status]).label}`}>
          <Button size="small" type="text" icon={<ArrowRightOutlined />} onClick={advance} />
        </Tooltip>
        <Tooltip title="Delete task">
          <Button size="small" type="text" danger icon={<DeleteOutlined />} onClick={() => onDelete(task)} />
        </Tooltip>
      </div>
    </article>
  )
}

function Board() {
  const [tasks, setTasks] = useState([])
  const [open, setOpen] = useState(false)
  const [priority, setPriority] = useState('ALL')
  const [form] = Form.useForm()
  const { message } = AntApp.useApp()

  const load = async () => {
    try {
      const res = await fetch(`${API}/tasks`)
      if (!res.ok) throw new Error()
      setTasks(await res.json())
    } catch {
      message.error('Cannot reach the backend. Start the stack, then reload.')
    }
  }

  useEffect(() => { load() }, [])

  const advance = async (task) => {
    await fetch(`${API}/tasks/${task.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: NEXT[task.status] }),
    })
    await load()
  }

  const remove = async (task) => {
    await fetch(`${API}/tasks/${task.id}`, { method: 'DELETE' })
    message.success('Task deleted')
    await load()
  }

  const create = async (values) => {
    const res = await fetch(`${API}/tasks`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(values),
    })
    if (!res.ok) return message.error('Could not create the task. Check the title and try again.')
    setOpen(false)
    form.resetFields()
    message.success('Task created')
    await load()
  }

  const counts = {
    ALL: tasks.length,
    HIGH: tasks.filter((t) => t.priority === 'HIGH').length,
    MEDIUM: tasks.filter((t) => t.priority === 'MEDIUM').length,
    LOW: tasks.filter((t) => t.priority === 'LOW').length,
  }
  const visible = priority === 'ALL' ? tasks : tasks.filter((t) => t.priority === priority)
  const done = tasks.filter((t) => t.status === 'DONE').length
  const pct = tasks.length ? Math.round((done / tasks.length) * 100) : 0

  const FILTERS = [
    { key: 'ALL', label: 'Everything', swatch: '#8e9ab3' },
    { key: 'HIGH', label: 'High priority', swatch: '#ce4257' },
    { key: 'MEDIUM', label: 'Medium', swatch: '#d9822b' },
    { key: 'LOW', label: 'Low', swatch: '#0e9b8a' },
  ]

  return (
    <div className="shell">
      <aside className="rail">
        <div className="wordmark">Task<span>Board</span></div>

        <Button type="primary" block icon={<PlusOutlined />} onClick={() => setOpen(true)}>
          New task
        </Button>

        <div className="rail-section">
          <span className="rail-label">Filter by priority</span>
          {FILTERS.map((f) => (
            <button
              key={f.key}
              className="filter"
              aria-pressed={priority === f.key}
              onClick={() => setPriority(f.key)}
            >
              <span className="swatch" style={{ background: f.swatch }} />
              {f.label}
              <span className="n">{counts[f.key]}</span>
            </button>
          ))}
        </div>

        <div className="progress-block">
          <div className="progress-read">
            <span>Completed</span>
            <b>{done} of {tasks.length}</b>
          </div>
          <Progress
            percent={pct}
            showInfo={false}
            size="small"
            strokeColor="#0e9b8a"
            trailColor="rgba(255,255,255,0.14)"
          />
        </div>

        <div className="whoami">
          <Avatar size={34} style={{ background: '#5b4bd6' }}>MS</Avatar>
          <div>
            <b>Manasvi Sabbarwal</b>
            <small>24BCS10406</small>
          </div>
        </div>
      </aside>

      <main className="board">
        <div className="board-head">
          <h1>Delivery board</h1>
          <span className="sub">
            {priority === 'ALL'
              ? 'Every task, grouped by stage'
              : `${FILTERS.find((f) => f.key === priority).label}, grouped by stage`}
          </span>
        </div>
        {COLUMNS.map((col) => {
          const items = visible.filter((t) => t.status === col.key)
          return (
            <section className="column" key={col.key}>
              <h2 className="column-head">
                <span className={`marker ${col.key.toLowerCase()}`} />
                {col.label}
                <span className="count">{items.length}</span>
              </h2>
              {items.length === 0 ? (
                <div className="empty-col">Nothing here yet</div>
              ) : (
                items.map((t) => (
                  <Card key={t.id} task={t} onAdvance={advance} onDelete={remove} />
                ))
              )}
            </section>
          )
        })}
      </main>

      <Modal
        title="Add a task"
        open={open}
        onCancel={() => setOpen(false)}
        onOk={() => form.submit()}
        okText="Create task"
        destroyOnClose
      >
        <Form
          form={form}
          layout="vertical"
          onFinish={create}
          initialValues={{ priority: 'MEDIUM', assignee: 'Manasvi Sabbarwal' }}
        >
          <Form.Item
            name="title"
            label="Title"
            rules={[{ required: true, message: 'Give the task a title' }]}
          >
            <Input placeholder="Configure production ingress" />
          </Form.Item>
          <Form.Item name="description" label="Description">
            <Input.TextArea rows={3} placeholder="What needs to be done?" />
          </Form.Item>
          <Form.Item name="priority" label="Priority">
            <Select
              options={Object.entries(PRIORITY).map(([value, p]) => ({ value, label: p.label }))}
            />
          </Form.Item>
          <Form.Item name="assignee" label="Assignee">
            <Input />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  )
}

const theme = {
  token: {
    colorPrimary: '#5b4bd6',
    colorInfo: '#5b4bd6',
    colorSuccess: '#0e9b8a',
    colorWarning: '#d9822b',
    colorError: '#ce4257',
    colorTextBase: '#16233a',
    fontFamily: "'IBM Plex Sans', system-ui, sans-serif",
    borderRadius: 8,
  },
}

createRoot(document.getElementById('root')).render(
  <ConfigProvider theme={theme}>
    <AntApp>
      <Board />
    </AntApp>
  </ConfigProvider>,
)
